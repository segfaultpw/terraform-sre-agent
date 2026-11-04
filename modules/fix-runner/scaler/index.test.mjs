import assert from "node:assert/strict";
import { test } from "node:test";

import { decide, fetchDemand, parseDemand, readConfig, run } from "./index.mjs";

const MINUTE = 60000;
const base = { pending: 0, running: 0, current: 0, min: 0, max: 5, concurrency: 1, idleMinutes: 10, idleSince: null, now: 1_000_000 };

test("work waiting starts as many tasks as it needs, up to the maximum", () => {
  assert.deepEqual(decide({ ...base, pending: 3 }), { desired: 3, idleSince: null, action: "scale_out", reason: "work is waiting or running" });
  assert.equal(decide({ ...base, pending: 9 }).desired, 5);
});

test("workers per task divide the demand, rounding up", () => {
  assert.equal(decide({ ...base, pending: 3, concurrency: 2 }).desired, 2);
  assert.equal(decide({ ...base, pending: 2, running: 2, concurrency: 4 }).desired, 1);
  assert.equal(decide({ ...base, pending: 4, running: 1, concurrency: 4 }).desired, 2);
});

test("running work counts toward the tasks needed", () => {
  assert.equal(decide({ ...base, running: 2, current: 0 }).desired, 2);
});

test("demand never scales in, however small", () => {
  const d = decide({ ...base, pending: 1, current: 4 });
  assert.equal(d.desired, 4);
  assert.equal(d.action, "hold");
});

test("the minimum is a floor even when nothing is waiting", () => {
  const d = decide({ ...base, min: 1, current: 0 });
  assert.equal(d.desired, 1);
  assert.equal(d.action, "scale_out");
});

test("idle at the minimum holds and forgets any idle mark", () => {
  const d = decide({ ...base, min: 1, current: 1, idleSince: 5 });
  assert.deepEqual(d, { desired: 1, idleSince: null, action: "hold", reason: "idle at the minimum" });
});

test("the first idle minute only starts the clock", () => {
  const d = decide({ ...base, current: 3 });
  assert.equal(d.desired, 3);
  assert.equal(d.idleSince, base.now);
  assert.equal(d.action, "hold");
});

test("idle for less than idle_minutes holds and keeps the original mark", () => {
  const idleSince = base.now - 9 * MINUTE;
  const d = decide({ ...base, current: 3, idleSince });
  assert.equal(d.desired, 3);
  assert.equal(d.idleSince, idleSince);
});

test("idle for idle_minutes scales in to the minimum", () => {
  const d = decide({ ...base, min: 1, current: 3, idleSince: base.now - 10 * MINUTE });
  assert.deepEqual(d, { desired: 1, idleSince: null, action: "scale_in", reason: "idle for idle_minutes" });
});

test("work arriving during the idle wait clears the clock", () => {
  const d = decide({ ...base, current: 3, pending: 1, idleSince: base.now - 9 * MINUTE });
  assert.equal(d.idleSince, null);
  assert.equal(d.desired, 3);
});

test("a task that is working holds the service up: running work stops the clock", () => {
  const d = decide({ ...base, current: 2, running: 1, idleSince: base.now - 30 * MINUTE });
  assert.equal(d.action, "hold");
  assert.equal(d.desired, 2);
  assert.equal(d.idleSince, null);
});

test("the demand answer is whole counts or it is refused", () => {
  assert.deepEqual(parseDemand({ pending: 1, running: 0, oldest_age_seconds: null, as_of: "x" }), { pending: 1, running: 0 });
  for (const bad of [null, {}, { pending: -1, running: 0 }, { pending: 1.5, running: 0 }, { pending: "1", running: 0 }, { pending: 1 }]) {
    assert.throws(() => parseDemand(bad), /demand endpoint/);
  }
});

function answer(status, body = { pending: 0, running: 0 }) {
  return { status, ok: status >= 200 && status < 300, json: async () => body };
}

function demandFetch(responses) {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    const next = responses.shift();
    if (next instanceof Error) throw next;
    return next;
  };
  return { fetchImpl, calls };
}

const noSleep = async () => {};

test("the demand call sends the key as a bearer to the demand path", async () => {
  const { fetchImpl, calls } = demandFetch([answer(200, { pending: 2, running: 1 })]);
  const demand = await fetchDemand({ fetchImpl, sleep: noSleep, url: "https://sre.example.com", key: "k-123" });
  assert.deepEqual(demand, { pending: 2, running: 1 });
  assert.equal(calls[0].url, "https://sre.example.com/api/fix_runner/demand");
  assert.equal(calls[0].options.headers.authorization, "Bearer k-123");
  assert.equal(calls[0].options.method, "GET");
});

test("a 500 is retried and a later 200 is used", async () => {
  const { fetchImpl, calls } = demandFetch([answer(500), answer(503), answer(200, { pending: 1, running: 0 })]);
  const demand = await fetchDemand({ fetchImpl, sleep: noSleep, url: "https://sre.example.com", key: "k" });
  assert.deepEqual(demand, { pending: 1, running: 0 });
  assert.equal(calls.length, 3);
});

test("a network error and a 429 are retried", async () => {
  const { fetchImpl, calls } = demandFetch([new Error("socket hang up"), answer(429), answer(200)]);
  await fetchDemand({ fetchImpl, sleep: noSleep, url: "https://sre.example.com", key: "k" });
  assert.equal(calls.length, 3);
});

test("three failures end the call with the reason", async () => {
  const { fetchImpl, calls } = demandFetch([answer(500), answer(500), answer(502)]);
  await assert.rejects(fetchDemand({ fetchImpl, sleep: noSleep, url: "https://sre.example.com", key: "k" }), /no demand after 3 attempts \(last failure: HTTP 502\)/);
  assert.equal(calls.length, 3);
});

test("a refused key or an older platform is not retried", async () => {
  for (const status of [401, 403, 404]) {
    const { fetchImpl, calls } = demandFetch([answer(status)]);
    await assert.rejects(fetchDemand({ fetchImpl, sleep: noSleep, url: "https://sre.example.com", key: "k" }), new RegExp(`answered ${status}`));
    assert.equal(calls.length, 1);
  }
});

test("an unreadable answer is not retried", async () => {
  const { fetchImpl, calls } = demandFetch([answer(200, { pending: "many" })]);
  await assert.rejects(fetchDemand({ fetchImpl, sleep: noSleep, url: "https://sre.example.com", key: "k" }), /demand endpoint/);
  assert.equal(calls.length, 1);
});

const config = { url: "https://sre.example.com", secretArn: "arn:secret", cluster: "c", service: "s", idleParameter: "/p", min: 0, max: 4, concurrency: 1, idleMinutes: 10 };

function awsError(name, status, message) {
  return Object.assign(new Error(message), { name, $metadata: { httpStatusCode: status } });
}

function fakeDeps({ responses, current = 0, idleSince = null, now = 1_000_000, setFails = false, getIdleFails = false, putIdleFails = false, secret = "  the-secret-key\n" }) {
  const { fetchImpl, calls } = demandFetch(responses);
  const state = { sets: [], idle: [], logs: [], calls, idleSince };
  const deps = {
    fetch: fetchImpl,
    sleep: noSleep,
    now: () => now,
    log: (line) => state.logs.push(line),
    getSecret: async () => secret,
    getDesiredCount: async () => current,
    getIdleSince: async () => {
      if (getIdleFails) throw awsError("ParameterNotFound", 400, "parameter /secret/path not found");
      return state.idleSince;
    },
    putIdleSince: async (value) => {
      if (putIdleFails) throw awsError("ThrottlingException", 400, "slow down");
      state.idle.push(value);
      state.idleSince = value;
    },
    setDesiredCount: async (count) => {
      if (setFails) throw awsError("InvalidParameterException", 400, "RunTask quota reached");
      state.sets.push(count);
    },
  };
  return { deps, state };
}

test("a run scales out to the demand and logs one decision line", async () => {
  const { deps, state } = fakeDeps({ responses: [answer(200, { pending: 3, running: 0 })] });
  const result = await run(deps, config);
  assert.deepEqual(state.sets, [3]);
  assert.equal(result.action, "scale_out");
  assert.equal(state.logs.length, 1);
  assert.deepEqual(state.logs[0], { msg: "decision", action: "scale_out", reason: "work is waiting or running", pending: 3, running: 0, current: 0, desired: 3 });
  assert.equal(state.calls[0].options.headers.authorization, "Bearer the-secret-key");
});

test("the key never appears in a log line", async () => {
  const { deps, state } = fakeDeps({ responses: [answer(200, { pending: 1, running: 0 })] });
  await run(deps, config);
  assert.ok(!JSON.stringify(state.logs).includes("the-secret-key"));
});

test("a demand 500 changes nothing and the run fails", async () => {
  const { deps, state } = fakeDeps({ responses: [answer(500), answer(500), answer(500)], current: 2 });
  await assert.rejects(run(deps, config), /no demand/);
  assert.deepEqual(state.sets, []);
  assert.deepEqual(state.idle, []);
  assert.deepEqual(state.logs, []);
});

test("a service that cannot be scaled logs the error's name and status, never its message, and fails the run", async () => {
  const { deps, state } = fakeDeps({ responses: [answer(200, { pending: 1, running: 0 })], setFails: true });
  await assert.rejects(run(deps, config), (error) => {
    assert.equal(error.message, "scaling the service failed (InvalidParameterException (HTTP 400))");
    return true;
  });
  const failure = state.logs.find((line) => line.level === "error");
  assert.equal(failure.msg, "scaling the service failed");
  assert.equal(failure.error, "InvalidParameterException (HTTP 400)");
  assert.ok(!JSON.stringify(state.logs).includes("RunTask quota"));
});

test("the idle mark is written when the clock starts and cleared when work returns", async () => {
  const first = fakeDeps({ responses: [answer(200)], current: 2 });
  await run(first.deps, config);
  assert.deepEqual(first.state.idle, [1_000_000]);
  assert.deepEqual(first.state.sets, []);

  const second = fakeDeps({ responses: [answer(200, { pending: 1, running: 0 })], current: 2, idleSince: 900_000 });
  await run(second.deps, config);
  assert.deepEqual(second.state.idle, [null]);
});

test("a long idle scales in once and clears the mark", async () => {
  const { deps, state } = fakeDeps({ responses: [answer(200), answer(200)], current: 2, idleSince: 1_000_000 - 11 * MINUTE });
  const result = await run(deps, config);
  assert.equal(result.action, "scale_in");
  assert.deepEqual(state.sets, [0]);
  assert.deepEqual(state.idle, [null]);
});

test("nothing is written when nothing changes", async () => {
  const { deps, state } = fakeDeps({ responses: [answer(200)], current: 0 });
  await run(deps, config);
  assert.deepEqual(state.sets, []);
  assert.deepEqual(state.idle, []);
});

const env = {
  SRE_AGENT_URL: "https://sre.example.com/",
  API_KEY_SECRET_ARN: "arn:secret",
  CLUSTER_ARN: "arn:cluster",
  SERVICE_NAME: "svc",
  IDLE_PARAMETER: "/idle",
  MIN_RUNNERS: "0",
  MAX_RUNNERS: "3",
  CONCURRENCY: "2",
  IDLE_MINUTES: "10",
};

test("the environment becomes the configuration", () => {
  const parsed = readConfig(env);
  assert.equal(parsed.url, "https://sre.example.com");
  assert.equal(parsed.max, 3);
  assert.equal(parsed.concurrency, 2);
});

test("a missing or malformed setting refuses to run", () => {
  assert.throws(() => readConfig({ ...env, SRE_AGENT_URL: "" }), /SRE_AGENT_URL/);
  assert.throws(() => readConfig({ ...env, MAX_RUNNERS: "x" }), /MAX_RUNNERS/);
  assert.throws(() => readConfig({ ...env, CONCURRENCY: "0" }), /CONCURRENCY/);
  assert.throws(() => readConfig({ ...env, MIN_RUNNERS: "4" }), /MAX_RUNNERS at least MIN_RUNNERS/);
});

// A lowered max_runners applies at once.

test("a count above a lowered maximum is cut to it, even while work keeps arriving", () => {
  const d = decide({ ...base, pending: 1, running: 5, current: 6, max: 2 });
  assert.deepEqual(d, { desired: 2, idleSince: null, action: "cap", reason: "above max_runners" });
});

test("a count above a lowered maximum is cut to it when idle, keeping the idle mark", () => {
  const d = decide({ ...base, current: 6, max: 2, idleSince: 777 });
  assert.equal(d.desired, 2);
  assert.equal(d.idleSince, 777);
  assert.equal(d.action, "cap");
});

// The idle clock is best effort for everything but scaling in.

test("an unreadable idle clock never blocks a scale-out", async () => {
  const { deps, state } = fakeDeps({ responses: [answer(200, { pending: 2, running: 0 })], current: 0, getIdleFails: true });
  await assert.rejects(run(deps, config), /idle clock parameter is unavailable \(ParameterNotFound \(HTTP 400\)\); scaling out is unaffected/);
  assert.deepEqual(state.sets, [2]);
});

test("an unreadable idle clock never scales in", async () => {
  const { deps, state } = fakeDeps({ responses: [answer(200)], current: 3, getIdleFails: true, idleSince: 1_000_000 - 60 * MINUTE });
  await assert.rejects(run(deps, config), /idle clock parameter is unavailable/);
  assert.deepEqual(state.sets, []);
  assert.equal(state.calls.length, 1);
});

test("an unwritable idle clock does not stop the scale-out that came first", async () => {
  const { deps, state } = fakeDeps({ responses: [answer(200, { pending: 1, running: 0 })], current: 0, idleSince: 5, putIdleFails: true });
  await assert.rejects(run(deps, config), /idle clock parameter is unavailable \(ThrottlingException \(HTTP 400\)\)/);
  assert.deepEqual(state.sets, [1]);
});

test("an unwritable idle clock does not stop a scale-in", async () => {
  const { deps, state } = fakeDeps({ responses: [answer(200), answer(200)], current: 2, idleSince: 1_000_000 - 11 * MINUTE, putIdleFails: true });
  await assert.rejects(run(deps, config), /idle clock parameter is unavailable/);
  assert.deepEqual(state.sets, [0]);
});

test("the SSM error's message never reaches a log line or the thrown error", async () => {
  const { deps, state } = fakeDeps({ responses: [answer(200, { pending: 1, running: 0 })], getIdleFails: true });
  await assert.rejects(run(deps, config), (error) => !error.message.includes("/secret/path"));
  assert.ok(!JSON.stringify(state.logs).includes("/secret/path"));
});

// A scale-in looks at demand again right before it acts.

test("work that arrives between the reads cancels the scale-in", async () => {
  const { deps, state } = fakeDeps({ responses: [answer(200), answer(200, { pending: 1, running: 0 })], current: 2, idleSince: 1_000_000 - 11 * MINUTE });
  const result = await run(deps, config);
  assert.equal(result.action, "hold");
  assert.equal(result.reason, "work arrived before the scale-in");
  assert.deepEqual(state.sets, []);
  assert.deepEqual(state.idle, [null]);
  assert.equal(state.logs.filter((line) => line.msg === "decision").length, 1);
  assert.equal(state.logs.find((line) => line.msg === "decision").pending, 1);
});

test("a demand call that fails right before a scale-in leaves the service alone", async () => {
  const { deps, state } = fakeDeps({ responses: [answer(200), answer(500), answer(500), answer(500)], current: 2, idleSince: 1_000_000 - 11 * MINUTE });
  await assert.rejects(run(deps, config), /no demand/);
  assert.deepEqual(state.sets, []);
});

test("a scale-out does not read demand a second time", async () => {
  const { deps, state } = fakeDeps({ responses: [answer(200, { pending: 1, running: 0 })], current: 0 });
  await run(deps, config);
  assert.equal(state.calls.length, 1);
});

// The key never reaches a log, whatever the fetch says.

test("a key with an inner line break is refused without a trace of it in any log or error", async () => {
  const planted = "abc\ndef-planted-key";
  const fetchLeaks = async (url, options) => {
    throw new TypeError(`Headers.append: "${options.headers.authorization}" is an invalid header value.`);
  };
  const { deps, state } = fakeDeps({ responses: [], secret: planted });
  deps.fetch = fetchLeaks;
  await assert.rejects(run(deps, config), (error) => {
    assert.ok(!error.message.includes("abc"));
    assert.ok(!error.message.includes("planted"));
    assert.match(error.message, /cannot be sent in a header/);
    return true;
  });
  assert.ok(!JSON.stringify(state.logs).includes("planted"));
  assert.deepEqual(state.sets, []);
});

test("an empty or spaced key is refused", async () => {
  for (const secret of ["", "   \n", "two words", "tab\there", "nul\u0000byte", "café"]) {
    const { deps } = fakeDeps({ responses: [], secret });
    await assert.rejects(run(deps, config), /cannot be sent in a header/);
  }
});

test("a fetch that throws a message quoting the key is retried and then reported by name only", async () => {
  const { deps, state } = fakeDeps({ responses: [], secret: "valid-key-123" });
  deps.fetch = async (url, options) => {
    throw Object.assign(new Error(`connect failed for ${options.headers.authorization}`), { name: "FetchError" });
  };
  await assert.rejects(run(deps, config), (error) => {
    assert.equal(error.message, "no demand after 3 attempts (last failure: FetchError)");
    return true;
  });
  assert.ok(!JSON.stringify(state.logs).includes("valid-key-123"));
});

test("an unreadable secret is reported by name, not message", async () => {
  const { deps, state } = fakeDeps({ responses: [] });
  deps.getSecret = async () => {
    throw awsError("AccessDeniedException", 400, "User arn:aws:iam::1:role/x is not authorized");
  };
  await assert.rejects(run(deps, config), (error) => {
    assert.equal(error.message, "reading the API key secret failed (AccessDeniedException (HTTP 400))");
    return true;
  });
  assert.ok(!JSON.stringify(state.logs).includes("not authorized"));
});

test("an answer that is not JSON is refused with fixed text", async () => {
  const { fetchImpl } = demandFetch([{ status: 200, ok: true, json: async () => { throw new SyntaxError("Unexpected token < in <html>secret</html>"); } }]);
  await assert.rejects(fetchDemand({ fetchImpl, sleep: noSleep, url: "https://sre.example.com", key: "k" }), (error) => {
    assert.equal(error.message, "the demand endpoint answered something that is not JSON");
    return true;
  });
});
