// Scales the fix runner service to SRE Agent's demand. It runs once a minute in your account: it
// reads how much work is waiting from the demand endpoint, sets the ECS service's desired count,
// and writes one log line per decision. It never touches a task and never sees a request's
// content: the endpoint answers counts only.

const DEMAND_PATH = "/api/fix_runner/demand";
const ATTEMPTS = 3;
const ATTEMPT_TIMEOUT_MS = 8000;
const RETRY_BASE_MS = 500;

export function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

// The whole policy, with no I/O. `idleSince` is the epoch millisecond at which the service was
// first seen with no pending and no running work, or null. The service scales out at once and
// scales in only after it has been idle for idleMinutes, and then straight to the minimum:
// a task that is working a request holds ECS scale-in protection, so a scale-in cannot end it.
export function decide({ pending, running, current, min, max, concurrency, idleMinutes, idleSince, now }) {
  const busy = pending + running > 0;
  const wanted = clamp(Math.ceil((pending + running) / concurrency), min, max);

  if (busy) {
    if (wanted > current) {
      return { desired: wanted, idleSince: null, action: "scale_out", reason: "work is waiting or running" };
    }
    return { desired: current, idleSince: null, action: "hold", reason: "enough tasks for the work" };
  }

  if (current < min) {
    return { desired: min, idleSince: null, action: "scale_out", reason: "below the minimum" };
  }

  if (current === min) {
    return { desired: current, idleSince: null, action: "hold", reason: "idle at the minimum" };
  }

  if (idleSince === null) {
    return { desired: current, idleSince: now, action: "hold", reason: "idle, waiting out idle_minutes" };
  }

  if (now - idleSince >= idleMinutes * 60000) {
    return { desired: min, idleSince: null, action: "scale_in", reason: "idle for idle_minutes" };
  }

  return { desired: current, idleSince, action: "hold", reason: "idle, waiting out idle_minutes" };
}

export function parseDemand(body) {
  const whole = (value) => Number.isInteger(value) && value >= 0;
  if (body === null || typeof body !== "object" || !whole(body.pending) || !whole(body.running)) {
    throw new Error("the demand endpoint answered something other than {pending, running} as whole numbers");
  }
  return { pending: body.pending, running: body.running };
}

// Three attempts for a network error, a timeout, a 429 or a 5xx. Any other status is the answer:
// 401 and 403 mean the key is refused, 404 that the platform is older than the demand endpoint,
// and none of them gets better by asking again.
export async function fetchDemand({ fetchImpl, sleep, url, key }) {
  let lastError;
  for (let attempt = 1; attempt <= ATTEMPTS; attempt++) {
    try {
      const response = await fetchImpl(`${url}${DEMAND_PATH}`, {
        method: "GET",
        headers: { authorization: `Bearer ${key}`, accept: "application/json" },
        signal: AbortSignal.timeout(ATTEMPT_TIMEOUT_MS),
      });
      if (response.status === 429 || response.status >= 500) {
        lastError = new Error(`the demand endpoint answered ${response.status}`);
      } else if (!response.ok) {
        throw Object.assign(new Error(`the demand endpoint answered ${response.status}`), { final: true });
      } else {
        try {
          return parseDemand(await response.json());
        } catch (error) {
          throw Object.assign(error, { final: true });
        }
      }
    } catch (error) {
      if (error.final) throw error;
      lastError = error;
    }
    if (attempt < ATTEMPTS) await sleep(RETRY_BASE_MS * attempt);
  }
  throw new Error(`no demand after ${ATTEMPTS} attempts: ${lastError.message}`);
}

export function readConfig(env) {
  const whole = (name) => {
    const value = Number(env[name]);
    if (!Number.isInteger(value) || value < 0) throw new Error(`${name} must be a whole number`);
    return value;
  };
  for (const name of ["SRE_AGENT_URL", "API_KEY_SECRET_ARN", "CLUSTER_ARN", "SERVICE_NAME", "IDLE_PARAMETER"]) {
    if (!env[name]) throw new Error(`${name} is not set`);
  }
  const config = {
    url: env.SRE_AGENT_URL.replace(/\/+$/, ""),
    secretArn: env.API_KEY_SECRET_ARN,
    cluster: env.CLUSTER_ARN,
    service: env.SERVICE_NAME,
    idleParameter: env.IDLE_PARAMETER,
    min: whole("MIN_RUNNERS"),
    max: whole("MAX_RUNNERS"),
    concurrency: whole("CONCURRENCY"),
    idleMinutes: whole("IDLE_MINUTES"),
  };
  if (config.concurrency < 1 || config.max < config.min) {
    throw new Error("CONCURRENCY must be at least 1 and MAX_RUNNERS at least MIN_RUNNERS");
  }
  return config;
}

// One invocation. Every collaborator is passed in, so the failure paths run without AWS.
export async function run(deps, config) {
  const key = (await deps.getSecret(config.secretArn)).trim();
  const demand = await fetchDemand({ fetchImpl: deps.fetch, sleep: deps.sleep, url: config.url, key });
  const current = await deps.getDesiredCount();
  const storedIdleSince = await deps.getIdleSince();
  const now = deps.now();

  const decision = decide({
    pending: demand.pending,
    running: demand.running,
    current,
    min: config.min,
    max: config.max,
    concurrency: config.concurrency,
    idleMinutes: config.idleMinutes,
    idleSince: storedIdleSince,
    now,
  });

  deps.log({
    msg: "decision",
    action: decision.action,
    reason: decision.reason,
    pending: demand.pending,
    running: demand.running,
    current,
    desired: decision.desired,
  });

  if (decision.idleSince !== storedIdleSince) await deps.putIdleSince(decision.idleSince);

  if (decision.desired !== current) {
    try {
      await deps.setDesiredCount(decision.desired);
    } catch (error) {
      deps.log({ level: "error", msg: "the service could not be scaled", desired: decision.desired, error: error.message });
      throw error;
    }
  }

  return { ...decision, current, pending: demand.pending, running: demand.running };
}

async function awsDeps(config) {
  const [{ ECSClient, DescribeServicesCommand, UpdateServiceCommand }, { SecretsManagerClient, GetSecretValueCommand }, { SSMClient, GetParameterCommand, PutParameterCommand }] =
    await Promise.all([import("@aws-sdk/client-ecs"), import("@aws-sdk/client-secrets-manager"), import("@aws-sdk/client-ssm")]);
  const ecs = new ECSClient({});
  const secrets = new SecretsManagerClient({});
  const ssm = new SSMClient({});

  return {
    fetch: globalThis.fetch,
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    now: () => Date.now(),
    log: (line) => console.log(JSON.stringify({ level: "info", ...line })),
    async getSecret(arn) {
      const answer = await secrets.send(new GetSecretValueCommand({ SecretId: arn }));
      if (typeof answer.SecretString !== "string") throw new Error("the API key secret holds no string value");
      return answer.SecretString;
    },
    async getDesiredCount() {
      const answer = await ecs.send(new DescribeServicesCommand({ cluster: config.cluster, services: [config.service] }));
      const service = (answer.services || [])[0];
      if (!service) throw new Error("the runner service was not found");
      return service.desiredCount;
    },
    async setDesiredCount(count) {
      await ecs.send(new UpdateServiceCommand({ cluster: config.cluster, service: config.service, desiredCount: count }));
    },
    async getIdleSince() {
      const answer = await ssm.send(new GetParameterCommand({ Name: config.idleParameter }));
      const stored = Number(answer.Parameter.Value);
      return Number.isInteger(stored) && stored > 0 ? stored : null;
    },
    async putIdleSince(value) {
      await ssm.send(new PutParameterCommand({ Name: config.idleParameter, Value: String(value === null ? 0 : value), Overwrite: true }));
    },
  };
}

export async function handler() {
  const config = readConfig(process.env);
  return run(await awsDeps(config), config);
}
