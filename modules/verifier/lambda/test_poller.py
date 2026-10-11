"""Tests for poller.py against a loopback platform and a fake ECS. No network, no AWS.

Run: python3 -m unittest discover -s verifier/poller
"""

import http.server
import json
import os
import threading
import unittest
import urllib.parse

import poller

DIGEST = "sha256:" + "a" * 64
IMAGE = "ghcr.io/segfaultpw/sre-agent-verifier-node@" + DIGEST

JOB = {
    "run_id": "11111111-1111-1111-1111-111111111111",
    "runtime": "node",
    "repository": "acme/api",
    "base_sha": "b" * 40,
    "size": {"cpu": 1024, "memory": 2048, "ephemeral_gib": 30},
    "wall_clock_seconds": 900,
    "max_output_bytes": 1000000,
    "bootstrap_url": "https://platform.test/webhooks/verifier/1/sig/bootstrap",
    "bootstrap_expires_at": "2026-10-10T00:00:00Z",
    "test_job": False,
}


class FakePlatform:
    """Answers GET /api/verifier/queue with a scripted (status, body), recording requests."""

    def __init__(self, status, body):
        self.requests = []
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                outer.requests.append({"path": self.path, "headers": dict(self.headers)})
                payload = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *_args):
                pass

        self.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:%d" % self.server.server_port
        threading.Thread(
            target=lambda: self.server.serve_forever(poll_interval=0.01), daemon=True
        ).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class FakeEcs:
    def __init__(self, failures=None):
        self.calls = []
        self.failures = failures or []

    def run_task(self, **request):
        self.calls.append(request)
        if self.failures:
            return {"tasks": [], "failures": self.failures}
        return {"tasks": [{"taskArn": "arn:aws:ecs:us-east-1:1:task/c/abc"}], "failures": []}


class FakeSecrets:
    def __init__(self):
        self.calls = 0

    def get_secret_value(self, SecretId):
        self.calls += 1
        return {"SecretString": "sre_ak_test_key\n"}


def environ(url, images=None):
    return {
        "SRE_AGENT_URL": url,
        "API_KEY_SECRET_ARN": "arn:aws:secretsmanager:us-east-1:1:secret:key",
        "IMAGES": json.dumps(images if images is not None else {"node": IMAGE}),
        "TASK_DEFINITIONS": json.dumps({"node": "arn:aws:ecs:us-east-1:1:task-definition/v-node:3"}),
        "CLUSTER_ARN": "arn:aws:ecs:us-east-1:1:cluster/v",
        "SUBNETS": "subnet-a,subnet-b",
        "SECURITY_GROUPS": "sg-1",
    }


class PollerTest(unittest.TestCase):
    def setUp(self):
        poller._api_key = None
        self.saved = dict(os.environ)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)

    def invoke(self, status, body, ecs=None, images=None):
        platform = FakePlatform(status, body)
        self.addCleanup(platform.close)
        os.environ.update(environ(platform.url, images))
        ecs = ecs or FakeEcs()
        result = poller.handler({}, None, ecs=ecs, secrets=FakeSecrets())
        return platform, ecs, result

    def test_digest_of_reads_only_pinned_references(self):
        self.assertEqual(poller.digest_of(IMAGE), DIGEST)
        self.assertIsNone(poller.digest_of("ghcr.io/x/y:latest"))
        self.assertIsNone(poller.digest_of("ghcr.io/x/y@sha256:short"))
        self.assertIsNone(poller.digest_of(None))

    def test_the_poll_reports_its_version_and_the_digest_of_every_image(self):
        platform, _ecs, _result = self.invoke(200, {"data": [], "refused": []})

        request = platform.requests[0]
        parsed = urllib.parse.urlparse(request["path"])
        self.assertEqual(parsed.path, "/api/verifier/queue")
        query = urllib.parse.parse_qs(parsed.query)
        self.assertEqual(query["poller_version"], [str(poller.POLLER_VERSION)])
        self.assertEqual(query["images[node]"], [DIGEST])
        headers = {name.lower(): value for name, value in request["headers"].items()}
        self.assertEqual(headers["authorization"], "Bearer sre_ak_test_key")

    def test_an_image_without_a_digest_is_not_reported(self):
        platform, _ecs, _result = self.invoke(200, {"data": []}, images={"node": "ghcr.io/x/y:latest"})
        self.assertNotIn("images%5Bnode%5D", platform.requests[0]["path"])

    def test_a_job_starts_the_task_with_the_bootstrap_url_as_its_only_variable(self):
        _platform, ecs, result = self.invoke(200, {"data": [JOB], "refused": []})

        self.assertEqual(result, {"status": 200, "jobs": 1, "started": 1})
        [request] = ecs.calls
        self.assertEqual(request["taskDefinition"], "arn:aws:ecs:us-east-1:1:task-definition/v-node:3")
        self.assertEqual(request["launchType"], "FARGATE")
        self.assertEqual(request["networkConfiguration"]["awsvpcConfiguration"]["assignPublicIp"], "DISABLED")
        self.assertEqual(request["overrides"]["cpu"], "1024")
        self.assertEqual(request["overrides"]["memory"], "2048")
        self.assertEqual(request["overrides"]["ephemeralStorage"], {"sizeInGiB": 30})
        [override] = request["overrides"]["containerOverrides"]
        self.assertEqual(override["environment"], [{"name": "BOOTSTRAP_URL", "value": JOB["bootstrap_url"]}])
        self.assertFalse(request["enableExecuteCommand"])
        wire = json.dumps(request)
        self.assertNotIn("sre_ak_test_key", wire)
        self.assertNotIn("AWS_", wire)

    def test_no_job_starts_nothing(self):
        _platform, ecs, result = self.invoke(200, {"data": [], "refused": []})
        self.assertEqual(result["jobs"], 0)
        self.assertEqual(ecs.calls, [])

    def test_a_runtime_with_no_task_definition_is_left_to_expire(self):
        job = dict(JOB, runtime="go")
        _platform, ecs, result = self.invoke(200, {"data": [job]})
        self.assertEqual(ecs.calls, [])
        self.assertEqual(result["started"], 0)

    def test_a_refused_run_task_is_logged_not_raised(self):
        _platform, ecs, result = self.invoke(200, {"data": [JOB]}, ecs=FakeEcs(failures=[{"reason": "CAPACITY"}]))
        self.assertEqual(len(ecs.calls), 1)
        self.assertEqual(result["started"], 0)

    def test_an_upgrade_required_answer_starts_nothing_and_does_not_fail(self):
        body = {"error": "runner_unknown", "message": "The node image is not an image SRE Agent published."}
        _platform, ecs, result = self.invoke(426, body)
        self.assertEqual(ecs.calls, [])
        self.assertEqual(result, {"status": 426, "error": "runner_unknown"})

    def test_the_hosted_mode_answer_backs_off(self):
        _platform, ecs, result = self.invoke(409, {"error": "hosted_mode", "message": "x"})
        self.assertEqual(ecs.calls, [])
        self.assertEqual(result["error"], "hosted_mode")

    def test_a_refused_key_is_reported_not_retried_into_a_crash(self):
        _platform, ecs, result = self.invoke(403, {"error": "insufficient_scope", "required": "verifier:poll"})
        self.assertEqual(ecs.calls, [])
        self.assertEqual(result["error"], "insufficient_scope")

    def test_an_unexpected_answer_fails_the_invocation(self):
        with self.assertRaises(RuntimeError):
            self.invoke(500, {"error": "boom"})

    def test_the_api_key_is_read_once_per_container(self):
        platform = FakePlatform(200, {"data": []})
        self.addCleanup(platform.close)
        os.environ.update(environ(platform.url))
        secrets = FakeSecrets()
        poller.handler({}, None, ecs=FakeEcs(), secrets=secrets)
        poller.handler({}, None, ecs=FakeEcs(), secrets=secrets)
        self.assertEqual(secrets.calls, 1)


if __name__ == "__main__":
    unittest.main()
