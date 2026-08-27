# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file except in compliance
# with the License. A copy of the License is located at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# or in the 'license' file accompanying this file. This file is distributed on an 'AS IS' BASIS, WITHOUT WARRANTIES
# OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions
# and limitations under the License.
"""Phase 3: E2E testing via test-infra (workflows/add-resource.md Phase 3).

Runs `make kind-test SERVICE=<service>` from the test-infra directory, classifies
the outcome (PASS / FAIL / SKIPPED), and applies the workflow's rules:

  - SKIPPED is treated as FAILURE — tests added by this workflow must actually
    execute via the bootstrap system, not gate on env vars.
  - On FAIL, dispatch the implementer with the failure details to fix, then
    re-run. Maximum `cfg.max_e2e_fix_attempts` (default 2) before escalating.

This phase is a fast-follow: the build-cluster ProwJob currently runs with
run_e2e=False (it lacks the privileged Docker-in-Docker + kind toolchain). The
code is kept intact and validated by the offline classifier/config tests so it
can be switched on once the build-cluster job grows a DinD/kind sidecar.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

import yaml

from .agents import AgentSet
from .config import Config

# Default: 45 minutes. E2E runs are 10-30+ minutes per the references.
_DEFAULT_E2E_TIMEOUT_S = 45 * 60


@dataclass
class E2EResult:
    status: str  # "PASS" | "FAIL" | "SKIPPED" | "NOT_RUN" | "ERROR"
    detail: str = ""
    attempts: int = 0
    artifacts_dir: str = ""
    fix_summaries: list[str] = field(default_factory=list)


def _to_snake(resource: str) -> str:
    """ResourceName -> resource_name (matches test_<resource>.py naming)."""
    s = re.sub(r"(.)([A-Z][a-z]+)", r"\1_\2", resource)
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", s)
    return s.lower()


def ensure_test_config(cfg: Config) -> tuple[bool, str]:
    """Ensure test_config.yaml exists and is configured for this resource's test.

    During a normal run the harness cannot know the test method name in advance,
    so it derives it (`test_<resource>`) and writes it into the config itself.
    Specifically this:
      - creates test_config.yaml from the example if missing;
      - sets tests.methods to [test_<resource>] so the run targets the resource
        this workflow added (overriding any stale prior filter);
      - enables debug.enabled + debug.dump_controller_logs so failures are
        diagnosable from $ARTIFACTS, per the Phase 3 SOP.

    It deliberately does NOT set aws.assumed_role_arn — that is environment
    specific and must already be present; we report it as a precondition rather
    than guessing a role ARN. Returns (ok, message).
    """
    ti = cfg.test_infra_dir
    if not ti.is_dir():
        return False, f"test-infra directory not found: {ti}"

    config_path = ti / "test_config.yaml"
    created = False
    if not config_path.is_file():
        example = ti / "test_config.example.yaml"
        if not example.is_file():
            return False, f"neither test_config.yaml nor test_config.example.yaml in {ti}"
        shutil.copyfile(example, config_path)
        created = True

    method = f"test_{_to_snake(cfg.resource)}"

    try:
        data = yaml.safe_load(config_path.read_text()) or {}
    except yaml.YAMLError as exc:
        return False, f"could not parse {config_path}: {exc}"

    # Target only this resource's test.
    tests = data.setdefault("tests", {})
    tests["methods"] = [method]

    # Ensure controller logs are dumped for diagnosis on failure.
    debug = data.setdefault("debug", {})
    debug["enabled"] = True
    debug["dump_controller_logs"] = True

    config_path.write_text(yaml.safe_dump(data, sort_keys=False, default_flow_style=False))

    role = (data.get("aws") or {}).get("assumed_role_arn")
    role_note = "" if role else (
        " WARNING: aws.assumed_role_arn is not set — the e2e run will fail until "
        "you configure a test role."
    )
    verb = "created and configured" if created else "configured"
    return True, f"{verb} {config_path} (tests.methods=[{method}], debug on).{role_note}"


def _classify(stdout: str, returncode: int) -> str:
    """Classify pytest/make output into PASS / FAIL / SKIPPED."""
    text = stdout.lower()
    # pytest summary line forms: "1 passed", "2 failed, 1 passed", "3 skipped"
    failed = bool(re.search(r"\b\d+\s+failed\b", text)) or "error" in text and returncode != 0
    skipped_only = bool(re.search(r"\b\d+\s+skipped\b", text)) and not re.search(
        r"\b\d+\s+passed\b", text
    )
    if returncode != 0 or failed:
        return "FAIL"
    if skipped_only:
        # Per the workflow, skipped tests added by this workflow are failures.
        return "SKIPPED"
    if re.search(r"\b\d+\s+passed\b", text):
        return "PASS"
    # Ambiguous output with rc==0 and no recognizable summary.
    return "FAIL"


def _run_make_kind_test(cfg: Config, artifacts: Path) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["ARTIFACTS"] = str(artifacts)
    timeout = cfg.extra.get("e2e_timeout_s", _DEFAULT_E2E_TIMEOUT_S)
    return subprocess.run(
        ["make", "kind-test", f"SERVICE={cfg.service}"],
        cwd=str(cfg.test_infra_dir),
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def _fix_prompt(cfg: Config, status: str, output_tail: str, artifacts: Path) -> str:
    if status == "SKIPPED":
        return (
            f"The e2e test for {cfg.resource} in the {cfg.service} controller was "
            "SKIPPED. Skipped tests are NOT acceptable — a test that skips due to "
            "missing environment variables or unmet preconditions was written in a "
            "way that cannot execute in the test harness. Rewrite the test to use "
            "the bootstrap system (service_bootstrap.py / bootstrap_resources.py) or "
            "create resources in fixtures, following existing tests in "
            f"{cfg.controller_dir}/test/e2e/tests/. Do NOT gate execution on env vars.\n\n"
            f"Test output (tail):\n{output_tail}"
        )
    return (
        f"The e2e test for {cfg.resource} in the {cfg.service} controller FAILED. "
        f"Read the controller logs in {artifacts}/ and the test output below, "
        "diagnose the root cause, and fix it (generator.yaml, hooks, or the test "
        "itself — never generated files). Then report what you changed.\n\n"
        f"Test output (tail):\n{output_tail}"
    )


def run_e2e(cfg: Config, agents: AgentSet) -> E2EResult:
    """Run Phase 3 with up to cfg.max_e2e_fix_attempts implementer fix cycles."""
    ok, msg = ensure_test_config(cfg)
    if not ok:
        return E2EResult(status="NOT_RUN", detail=msg)

    artifacts = Path(os.environ.get("ARTIFACTS") or "/tmp/ack-test-logs")
    artifacts.mkdir(parents=True, exist_ok=True)

    result = E2EResult(status="NOT_RUN", detail=msg, artifacts_dir=str(artifacts))

    # 1 initial run + up to max_e2e_fix_attempts fix-and-rerun cycles.
    max_runs = cfg.max_e2e_fix_attempts + 1
    for attempt in range(1, max_runs + 1):
        result.attempts = attempt
        try:
            proc = _run_make_kind_test(cfg, artifacts)
        except subprocess.TimeoutExpired as exc:
            result.status = "ERROR"
            result.detail = f"make kind-test timed out after {exc.timeout}s on attempt {attempt}"
            return result
        except FileNotFoundError:
            result.status = "ERROR"
            result.detail = "`make` not found — is the test-infra toolchain installed?"
            return result

        combined = (proc.stdout or "") + "\n" + (proc.stderr or "")
        status = _classify(combined, proc.returncode)
        tail = "\n".join(combined.splitlines()[-60:])
        result.status = status
        result.detail = tail

        if status == "PASS":
            return result

        if attempt >= max_runs:
            result.detail = (
                f"E2E still {status} after {attempt} attempt(s); escalating to user.\n\n{tail}"
            )
            return result

        # Dispatch the implementer to fix, then loop to re-run.
        fix = agents.implementer(_fix_prompt(cfg, status, tail, artifacts))
        result.fix_summaries.append(str(fix))

    return result
