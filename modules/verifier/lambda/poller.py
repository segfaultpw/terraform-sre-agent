"""The customer-run verifier's poller: an AWS Lambda that asks SRE Agent for work and
starts the verifier image for it in this account.

Run on a schedule (every minute). One invocation is one poll:

  1. read the organization's API key (scope verifier:poll) from Secrets Manager;
  2. GET <SRE_AGENT_URL>/api/verifier/queue, reporting POLLER_VERSION and the digest of
     the image it would start for each runtime;
  3. for the job it is handed (at most one), run the published verifier image as a
     Fargate task with the job's bootstrap URL as the ONE environment variable.

It never connects to anything but SRE Agent (HTTPS, outbound) and ECS in this account.
The platform never connects to it. The job holds no credential of ours: a single-claim
URL that expires in minutes. The task claims it, receives its read-only repository token
and the patch, runs, and reports to a signed URL; this function sees none of that.

The contract is verifier/contract.md and SreWeb.API.VerifierQueueController in the
sre-agent repository. A copy of this file ships in the `verifier` module of
terraform-sre-agent; keep the two identical.

Standard library only, plus boto3 which the Lambda runtime provides.
"""

import json
import os
import urllib.error
import urllib.parse
import urllib.request

POLLER_VERSION = 1

# The platform's own answers a poller must not treat as a failure of the poller.
BACK_OFF = {"feature_not_available", "hosted_mode"}

_api_key = None


def digest_of(image):
    """The sha256 digest of an image reference pinned by digest, or None."""
    if not isinstance(image, str) or "@" not in image:
        return None
    digest = image.rsplit("@", 1)[1]
    return digest if digest.startswith("sha256:") and len(digest) == 71 else None


def reported_images(images):
    """runtime -> digest for every configured image; a reference without a digest is left out."""
    return {runtime: digest_of(image) for runtime, image in images.items() if digest_of(image)}


def queue_url(base_url, images):
    query = [("poller_version", str(POLLER_VERSION))]
    query += [("images[%s]" % runtime, digest) for runtime, digest in sorted(reported_images(images).items())]
    return "%s/api/verifier/queue?%s" % (base_url.rstrip("/"), urllib.parse.urlencode(query))


def poll(base_url, api_key, images, opener=urllib.request.urlopen, timeout=20):
    """One poll. Returns (status, body) where body is the decoded JSON answer.

    A refusal is data, not an exception: the caller logs its code and message.
    """
    request = urllib.request.Request(
        queue_url(base_url, images),
        headers={"authorization": "Bearer " + api_key, "accept": "application/json"},
    )
    try:
        with opener(request, timeout=timeout) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        try:
            body = json.loads(error.read() or b"{}")
        except ValueError:
            body = {}
        finally:
            error.close()
        return error.code, body


def run_task_request(job, config):
    """The ECS RunTask request for a job: the job's bootstrap URL and nothing else."""
    runtime = job["runtime"]
    size = job["size"]
    return {
        "cluster": config["cluster"],
        "taskDefinition": config["task_definitions"][runtime],
        "launchType": "FARGATE",
        "count": 1,
        "startedBy": "sre-agent-verifier-poller",
        "enableExecuteCommand": False,
        "networkConfiguration": {
            "awsvpcConfiguration": {
                "subnets": config["subnets"],
                "securityGroups": config["security_groups"],
                "assignPublicIp": "DISABLED",
            }
        },
        "overrides": {
            "cpu": str(size["cpu"]),
            "memory": str(size["memory"]),
            "ephemeralStorage": {"sizeInGiB": size["ephemeral_gib"]},
            "containerOverrides": [
                {
                    "name": config["container_name"],
                    "environment": [{"name": "BOOTSTRAP_URL", "value": job["bootstrap_url"]}],
                }
            ],
        },
    }


def start_job(job, config, ecs):
    """Starts the task for one job. Answers the task ARN, or None when ECS refused."""
    if job.get("runtime") not in config["task_definitions"]:
        log("error", "no task definition for runtime %r; the job is left to expire" % job.get("runtime"))
        return None
    response = ecs.run_task(**run_task_request(job, config))
    if response.get("failures"):
        log("error", "RunTask refused job %s: %s" % (job.get("run_id"), response["failures"]))
        return None
    return response["tasks"][0]["taskArn"]


def log(level, message):
    print(json.dumps({"level": level, "message": message}))


def load_config(env=os.environ):
    return {
        "base_url": env["SRE_AGENT_URL"],
        "secret_arn": env["API_KEY_SECRET_ARN"],
        "images": json.loads(env["IMAGES"]),
        "task_definitions": json.loads(env["TASK_DEFINITIONS"]),
        "cluster": env["CLUSTER_ARN"],
        "subnets": env["SUBNETS"].split(","),
        "security_groups": env["SECURITY_GROUPS"].split(","),
        "container_name": env.get("CONTAINER_NAME", "verifier"),
    }


def api_key(config, secrets):
    global _api_key
    if _api_key is None:
        _api_key = secrets.get_secret_value(SecretId=config["secret_arn"])["SecretString"].strip()
    return _api_key


def handler(event=None, context=None, ecs=None, secrets=None, opener=urllib.request.urlopen):
    config = load_config()
    if ecs is None or secrets is None:
        import boto3

        ecs = ecs or boto3.client("ecs")
        secrets = secrets or boto3.client("secretsmanager")

    status, body = poll(config["base_url"], api_key(config, secrets), config["images"], opener=opener)

    if status == 200:
        started = [start_job(job, config, ecs) for job in body.get("data", [])]
        for refusal in body.get("refused", []):
            log("warn", "not given work for %s: %s" % (refusal.get("runtime"), refusal.get("message")))
        return {"status": status, "jobs": len(started), "started": len([arn for arn in started if arn])}

    code = body.get("error", "unknown")
    message = body.get("message", "")

    if status == 426:
        log("error", "the platform will not hand work to this poller (%s): %s" % (code, message))
    elif status in (401, 403) and code not in BACK_OFF:
        log("error", "the API key was refused (%s): check that it carries the verifier:poll scope" % code)
    elif code in BACK_OFF:
        log("warn", "nothing to do (%s): %s" % (code, message))
    else:
        raise RuntimeError("unexpected answer %s %s: %s" % (status, code, message))

    return {"status": status, "error": code}
