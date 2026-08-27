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
"""Top-level orchestration of the role-based add-resource workflow.

Wraps the Strands graph (Phases 1, 1.5, 2) and the E2E phase (Phase 3), then
produces the Phase 4 completion report. The graph holds the plan/review/impl
loop state; this module holds the cross-phase state and the final reporting.

`run()` is synchronous (it drives the graph via `asyncio.run` internally). The
workflow adapter calls it off the event loop (via `asyncio.to_thread`) so the
graph's own loop and the E2E phase's blocking subprocess never nest inside an
already-running loop.
"""

from __future__ import annotations

import asyncio
import os
from dataclasses import dataclass, field

from strands.multiagent.graph import Graph, GraphResult

from . import e2e
from . import graph as graphmod
from .agents import AgentSet, build_agents
from .config import Config
from .progress import ProgressReporter
from .verdict import Decision, parse_decision


def configure_headless_env(cfg: Config) -> None:
    """Put the strands_tools shell/editor/file_write tools in non-interactive mode.

    Those tools prompt for confirmation by default; this workflow runs
    unattended (in a ProwJob, or a local background run), so enable the
    documented bypass + non-interactive modes unless the operator already set
    them. Also cap every shell command at cfg.shell_timeout_s seconds so a
    pathological command (e.g. `find /` or a recursive grep over a broad root)
    is killed and returned as an error instead of stalling the whole run.
    """
    os.environ.setdefault("BYPASS_TOOL_CONSENT", "true")
    os.environ.setdefault("STRANDS_NON_INTERACTIVE", "true")
    os.environ["SHELL_DEFAULT_TIMEOUT"] = str(cfg.shell_timeout_s)


def build_task_prompt(cfg: Config) -> str:
    """The initial task handed to the graph entry point (and visible to all nodes).

    Carries the workflow inputs (SERVICE/RESOURCE/CONTROLLER_DIR/CODEGEN_DIR) so
    every node knows the target, exactly as workflows/add-resource.md specifies.
    """
    sdk = cfg.aws_sdk_go_version or "(detect from controller go.mod)"
    return (
        f"Add the {cfg.resource} resource to the {cfg.service} ACK service controller.\n\n"
        f"SERVICE={cfg.service}\n"
        f"RESOURCE={cfg.resource}\n"
        f"CONTROLLER_DIR={cfg.controller_dir}\n"
        f"CODEGEN_DIR={cfg.codegen_dir}\n"
        f"AWS_SDK_GO_VERSION={sdk}\n\n"
        "Execute your role for this resource. Planner: produce the plan document. "
        "Reviewer: produce a review document whose first line is "
        "'## Decision: APPROVE' or '## Decision: REVISE'. Implementer: apply the "
        "plan (or address the review feedback), build, and summarize your changes."
    )


@dataclass
class RunResult:
    cfg: Config
    graph_result: GraphResult | None = None
    graph_status: str = "UNKNOWN"
    plan_text: str = ""
    plan_review_text: str = ""
    impl_summary_text: str = ""
    final_review_text: str = ""
    # None means the impl reviewer never produced a verdict (e.g. the graph
    # halted before it ran). This is distinct from a real REVISE decision.
    impl_decision: Decision | None = None
    impl_reviewer_ran: bool = False
    impl_iterations: int = 0
    replan_attempts: int = 0
    e2e: e2e.E2EResult | None = None
    notes: list[str] = field(default_factory=list)

    @property
    def approved(self) -> bool:
        return self.impl_decision == Decision.APPROVE


def _latest_text(result: GraphResult, node_id: str) -> str:
    node_result = result.results.get(node_id)
    if node_result is None:
        return ""
    agent_results = node_result.get_agent_results()
    return str(agent_results[-1]) if agent_results else ""


def _count_runs(result: GraphResult, node_id: str) -> int:
    return sum(1 for n in result.execution_order if n.node_id == node_id)


async def _run_graph(cfg: Config, graph: Graph, reporter: ProgressReporter | None) -> GraphResult:
    """Drive the graph via stream_async, rendering node-level progress.

    Returns the final GraphResult. Using stream_async (rather than the blocking
    call) is what lets us emit tagged, node-aware progress in real time.
    """
    task = build_task_prompt(cfg)
    invocation_state = graphmod.invocation_state_for(cfg)
    gres: GraphResult | None = None
    async for event in graph.stream_async(task, invocation_state=invocation_state):
        if reporter is not None:
            reporter.handle(event)
        if event.get("type") == "multiagent_result":
            gres = event.get("result")
    if gres is None:
        raise RuntimeError("graph stream completed without a final result event")
    return gres


def run(
    cfg: Config,
    *,
    agents: AgentSet | None = None,
    graph: Graph | None = None,
    verbose: bool = False,
    progress: bool = True,
) -> RunResult:
    """Execute the full add-resource workflow for cfg.

    progress=True renders node-level progress (which agent is acting + verdicts);
    verbose=True additionally streams each agent's incremental text.
    """
    configure_headless_env(cfg)

    agents = agents or build_agents(cfg)
    graph = graph or graphmod.build_graph(cfg, agents)

    run_result = RunResult(cfg=cfg)
    reporter = ProgressReporter(verbose=verbose) if (progress or verbose) else None

    # --- Phases 1, 1.5, 2: the Strands graph ---------------------------------
    gres = asyncio.run(_run_graph(cfg, graph, reporter))
    run_result.graph_result = gres
    run_result.graph_status = getattr(gres.status, "name", str(gres.status))
    run_result.plan_text = _latest_text(gres, graphmod.PLANNER)
    run_result.plan_review_text = _latest_text(gres, graphmod.PLAN_REVIEWER)
    run_result.impl_summary_text = _latest_text(gres, graphmod.IMPLEMENTER)
    run_result.final_review_text = _latest_text(gres, graphmod.IMPL_REVIEWER)
    run_result.impl_iterations = _count_runs(gres, graphmod.IMPLEMENTER)
    run_result.replan_attempts = max(0, _count_runs(gres, graphmod.PLANNER) - 1)

    # Distinguish "reviewer never ran" from "reviewer said REVISE". Only parse a
    # decision when the impl reviewer actually produced output.
    run_result.impl_reviewer_ran = bool(run_result.final_review_text.strip())
    if run_result.impl_reviewer_ran:
        run_result.impl_decision = parse_decision(run_result.final_review_text)
    else:
        run_result.impl_decision = None

    if not run_result.impl_reviewer_ran:
        run_result.notes.append(
            "The implementation reviewer never produced a verdict — the graph "
            f"halted (status: {run_result.graph_status}) after "
            f"{run_result.impl_iterations} implementer iteration(s) but before "
            "review completed. This often means a node hit the execution/node "
            "timeout (e.g. a tool call stalled). Re-run to get a real review; "
            "results below are the implementer's own summary."
        )
    elif not run_result.approved:
        run_result.notes.append(
            "Implementation loop ended without Reviewer APPROVE "
            f"(after {run_result.impl_iterations} implementer iteration(s)); "
            "see final review for unresolved items."
        )

    # --- Phase 3: E2E testing ------------------------------------------------
    if cfg.run_e2e:
        run_result.e2e = e2e.run_e2e(cfg, agents)
    else:
        run_result.notes.append("Phase 3 (E2E) skipped by configuration.")

    return run_result


def completion_report(rr: RunResult) -> str:
    """Phase 4: human-readable completion report."""
    cfg = rr.cfg
    lines: list[str] = []
    lines.append(f"# Add-Resource Report: {cfg.service}/{cfg.resource}\n")

    lines.append("## Result")
    decision_str = rr.impl_decision.value if rr.impl_decision is not None else "NO VERDICT (reviewer did not run)"
    lines.append(f"- Reviewer decision: **{decision_str}**")
    lines.append(f"- Graph status: {rr.graph_status}")
    lines.append(f"- Implementer iterations: {rr.impl_iterations} (max {cfg.max_impl_iterations})")
    lines.append(f"- Re-plan attempts: {rr.replan_attempts} (max {cfg.max_replan_attempts})")
    if rr.e2e is not None:
        lines.append(f"- E2E status: **{rr.e2e.status}**")
    else:
        lines.append("- E2E status: not run")
    lines.append("")

    if rr.notes:
        lines.append("## Notes")
        lines.extend(f"- {n}" for n in rr.notes)
        lines.append("")

    lines.append("## Plan (summary)")
    lines.append(_head(rr.plan_text, 40) or "_no plan produced_")
    lines.append("")

    lines.append("## Final Review")
    lines.append(_head(rr.final_review_text, 40) or "_no review produced_")
    lines.append("")

    if rr.e2e is not None:
        lines.append("## E2E Detail")
        lines.append(rr.e2e.detail or "_no detail_")
        lines.append("")

    lines.append("## Next Steps")
    if not rr.impl_reviewer_ran:
        lines.append("- Re-run the workflow — the review phase did not complete (see Notes)")
    lines.append("- Squash commits into a single commit")
    lines.append("- Open a PR (or push to the existing branch)")
    if not rr.approved or (rr.e2e and rr.e2e.status != "PASS"):
        lines.append("- Resolve the unresolved items above before submitting")
    return "\n".join(lines)


def _head(text: str, n: int) -> str:
    if not text:
        return ""
    rows = text.splitlines()
    return "\n".join(rows[:n]) + ("\n…" if len(rows) > n else "")
