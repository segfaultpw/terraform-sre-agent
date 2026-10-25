"""The CloudWatch metric filter in main.tf must match what poller.py prints.

The poller returns normally after logging a 426, a refused RunTask or a job for a runtime with
no task definition at level error, so Lambda's own Errors metric never counts them; the module
alarms on a log metric filter instead. This pins the filter's pattern to the lines the poller
really prints on those paths, and keeps its quiet paths (a warning) from matching.

Run: python3 -m unittest discover -s modules/verifier/lambda
"""

import contextlib
import io
import json
import os
import re
import unittest

import poller
from test_poller import JOB, FakeEcs, FakePlatform, FakeSecrets, environ

MAIN_TF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "main.tf")

# A CloudWatch JSON filter pattern with one equality: { $.level = "error" }
FILTER = re.compile(r'^\{\s*\$\.(?P<field>[A-Za-z_]+)\s*=\s*"(?P<value>[a-z]+)"\s*\}$')


def declared_pattern():
    with open(MAIN_TF, encoding="utf-8") as handle:
        source = handle.read()
    block = re.search(r'resource "aws_cloudwatch_log_metric_filter" "poller_error_lines" \{(.*?)\n\}', source, re.S)
    assert block, "main.tf has no aws_cloudwatch_log_metric_filter.poller_error_lines"
    pattern = re.search(r'pattern\s*=\s*"((?:[^"\\]|\\.)*)"', block.group(1))
    assert pattern, "the filter declares no pattern"
    return pattern.group(1).replace('\\"', '"')


class LogFilterTest(unittest.TestCase):
    def setUp(self):
        poller._api_key = None
        self.saved = dict(os.environ)
        match = FILTER.match(declared_pattern())
        self.assertIsNotNone(match, "the pattern is not a simple JSON equality filter")
        self.field, self.value = match.group("field"), match.group("value")

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)

    def matches(self, line):
        try:
            record = json.loads(line)
        except ValueError:
            return False
        return isinstance(record, dict) and record.get(self.field) == self.value

    def matching(self, lines):
        return [line for line in lines if self.matches(line)]

    def lines_of(self, status, body, ecs=None, images=None):
        platform = FakePlatform(status, body)
        self.addCleanup(platform.close)
        os.environ.update(environ(platform.url, images))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            result = poller.handler({}, None, ecs=ecs or FakeEcs(), secrets=FakeSecrets())
        return result, [line for line in out.getvalue().splitlines() if line]

    def test_a_426_returns_normally_and_logs_a_line_the_filter_matches(self):
        body = {"error": "runner_unknown", "message": "The node image is not an image SRE Agent published."}
        result, lines = self.lines_of(426, body)

        self.assertEqual(result, {"status": 426, "error": "runner_unknown"})
        self.assertEqual(len(self.matching(lines)), 1)

    def test_a_refused_run_task_returns_normally_and_logs_a_line_the_filter_matches(self):
        result, lines = self.lines_of(
            200, {"data": [JOB], "refused": []}, ecs=FakeEcs(failures=[{"reason": "CAPACITY"}])
        )

        self.assertEqual(result, {"status": 200, "jobs": 1, "started": 0})
        self.assertEqual(len(self.matching(lines)), 1)

    def test_a_runtime_with_no_task_definition_logs_a_line_the_filter_matches(self):
        job = dict(JOB, runtime="go")
        result, lines = self.lines_of(200, {"data": [job], "refused": []})

        self.assertEqual(result, {"status": 200, "jobs": 1, "started": 0})
        self.assertEqual(len(self.matching(lines)), 1)

    def test_a_back_off_answer_is_a_warning_the_filter_ignores(self):
        _result, lines = self.lines_of(409, {"error": "hosted_mode", "message": "x"})

        self.assertTrue(lines)
        self.assertEqual(self.matching(lines), [])

    def test_a_poll_that_works_logs_nothing_the_filter_matches(self):
        _result, lines = self.lines_of(200, {"data": [], "refused": []})

        self.assertEqual(self.matching(lines), [])


if __name__ == "__main__":
    unittest.main()
