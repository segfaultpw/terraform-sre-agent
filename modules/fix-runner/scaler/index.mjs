// Scales the fix runner service to SRE Agent's demand. It runs once a minute in your account: it
// reads how much work is waiting from the demand endpoint, sets the ECS service's desired count,
// and writes one log line per decision. It never touches a task and never sees a request's
// content: the endpoint answers counts only.
//
// No error's message is ever logged or rethrown: a failed fetch can quote the request it was
// making, and that request carries the API key. Only an error's name, an HTTP status and this
// file's own fixed text reach the log.

const DEMAND_PATH = "/api/fix_runner/demand";
const ATTEMPTS = 3;
const ATTEMPT_TIMEOUT_MS = 8000;
const RETRY_BASE_MS = 500;
const KEY_PATTERN = /^[\x21-\x7e]+$/;

export function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

export function errorName(error) {
  return error && typeof error.name === "string" && error.name !== "" ? error.name : "Error";
}

// What may be said about a failure: its name and, for an AWS error, the HTTP status. Never its message.
export function describeFailure(error) {
  const status = error && error.$metadata && error.$metadata.httpStatusCode;
  return Number.isInteger(status) ? `${errorName(error)} (HTTP ${status})` : errorName(error);
}

// The whole policy, with no I/O. `idleSince` is the epoch millisecond at which the service was
// first seen with no pending and no running work, null when it was not, and undefined when the
// clock could not be read. The service scales out at once and without the clock; it scales in only
// after the clock has been read and shows idle_minutes elapsed, and then straight to the minimum:
// a task that is working a request holds ECS scale-in protection, so a scale-in cannot end it.
// A lowered max_runners applies at once, busy or not. The returned idleSince is what to store,
// undefined when nothing should be written.
export function decide({ pending, running, current, min, max, concurrency, idleMinutes, idleSince, now }) {
  const busy = pending + running > 0;

  if (current > max) {
    return { desired: max, idleSince: busy ? null : idleSince, action: "cap", reason: "above max_runners" };
  }

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

  if (idleSince === undefined) {
    return { desired: current, idleSince: undefined, action: "hold", reason: "idle, but the idle clock is unreadable" };
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

function final(message) {
  return Object.assign(new Error(message), { final: true });
}

// Three attempts for a network error, a timeout, a 429 or a 5xx. Any other status is the answer:
// 401 and 403 mean the key is refused, 404 that the platform is older than the demand endpoint,
// and none of them gets better by asking again.
export async function fetchDemand({ fetchImpl, sleep, url, key }) {
  let lastFailure = "no answer";
  for (let attempt = 1; attempt <= ATTEMPTS; attempt++) {
    try {
      const response = await fetchImpl(`${url}${DEMAND_PATH}`, {
        method: "GET",
        headers: { authorization: `Bearer ${key}`, accept: "application/json" },
        signal: AbortSignal.timeout(ATTEMPT_TIMEOUT_MS),
      });
      if (response.status === 429 || response.status >= 500) {
        lastFailure = `HTTP ${response.status}`;
      } else if (!response.ok) {
        throw final(`the demand endpoint answered ${response.status}`);
      } else {
        let body;
        try {
          body = await response.json();
        } catch {
          throw final("the demand endpoint answered something that is not JSON");
        }
        try {
          return parseDemand(body);
        } catch (error) {
          throw final(error.message);
        }
      }
    } catch (error) {
      if (error.final) throw error;
      lastFailure = describeFailure(error);
    }
    if (attempt < ATTEMPTS) await sleep(RETRY_BASE_MS * attempt);
  }
  throw new Error(`no demand after ${ATTEMPTS} attempts (last failure: ${lastFailure})`);
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

// A step whose failure stops the run, reported by name and status only.
async function must(deps, label, step) {
  try {
    return await step();
  } catch (error) {
    const failure = describeFailure(error);
    deps.log({ level: "error", msg: `${label} failed`, error: failure });
    throw new Error(`${label} failed (${failure})`);
  }
}

// One invocation. Every collaborator is passed in, so the failure paths run without AWS.
export async function run(deps, config) {
  const key = (await must(deps, "reading the API key secret", () => deps.getSecret(config.secretArn))).trim();
  if (!KEY_PATTERN.test(key)) {
    throw new Error("the API key secret is empty or holds characters that cannot be sent in a header (it must be the plain key, with no spaces or line breaks inside)");
  }

  const demand = await fetchDemand({ fetchImpl: deps.fetch, sleep: deps.sleep, url: config.url, key });
  const current = await must(deps, "reading the service", () => deps.getDesiredCount());

  // The clock only matters for scaling in, so a failure to read it must not stop a scale-out.
  let storedIdleSince;
  let clockFailure = null;
  try {
    storedIdleSince = await deps.getIdleSince();
  } catch (error) {
    clockFailure = describeFailure(error);
    deps.log({ level: "error", msg: "the idle clock could not be read", error: clockFailure });
  }

  const now = deps.now();
  let decision = decide({
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

  // Work can arrive between the first read and the change, and a task that has just collected a job
  // may not hold protection yet, so look again right before stopping anything.
  if (decision.action === "scale_in") {
    const again = await fetchDemand({ fetchImpl: deps.fetch, sleep: deps.sleep, url: config.url, key });
    if (again.pending + again.running > 0) {
      decision = { desired: current, idleSince: null, action: "hold", reason: "work arrived before the scale-in" };
      demand.pending = again.pending;
      demand.running = again.running;
    }
  }

  deps.log({
    msg: "decision",
    action: decision.action,
    reason: decision.reason,
    pending: demand.pending,
    running: demand.running,
    current,
    desired: decision.desired,
  });

  if (decision.desired !== current) {
    await must(deps, "scaling the service", () => deps.setDesiredCount(decision.desired));
  }

  if (decision.idleSince !== undefined && decision.idleSince !== storedIdleSince) {
    try {
      await deps.putIdleSince(decision.idleSince);
    } catch (error) {
      clockFailure = clockFailure || describeFailure(error);
      deps.log({ level: "error", msg: "the idle clock could not be written", error: describeFailure(error) });
    }
  }

  // After the scaling is done, so a clock that is down shows in the function's errors (and the
  // alarm) without ever having held a scale-out back.
  if (clockFailure !== null) {
    throw new Error(`the idle clock parameter is unavailable (${clockFailure}); scaling out is unaffected, but the service will not scale in until it is`);
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
