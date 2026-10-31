#!/usr/bin/env python3
"""Plan the native tmux cells from priv/tmux/support.json and the event.

A push and a pull request used to build and test every required tmux release,
although the oldest and newest bracket the rest. This script decides what a run
covers, so the workflow lists no version.

Scopes:

- edges: the oldest and newest required release on the reference toolchain,
  and the tracking toolchain on the newest. The default for a push, a pull
  request and a dispatch.
- full: every required release on the reference toolchain, and the tracking
  toolchain on the newest. A release, a schedule and a dispatch that asks.
- custom: only the tmux versions, tags, branches or commits a dispatch names,
  on the reference toolchain.

Usage:
    python3 scripts/ci_plan.py plan --event EVENT [--scope S] [--tmux-ref REFS]
        [--elixir V] [--otp V] [--os IMAGE] [--tmate MODE]
        [--github-output FILE] [--summary FILE]
"""
import argparse
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tmux_ref import FULL_COMMIT, check_ref

SUPPORT = Path(__file__).resolve().parent.parent / "priv/tmux/support.json"

SCOPES = ("edges", "full", "custom")
EVENT_SCOPES = {"push": "edges", "pull_request": "edges", "workflow_dispatch": "edges", "schedule": "full"}
TMATE_MODES = ("off", "before-tests", "on-failure")
RUNNERS = ("ubuntu-24.04", "ubuntu-latest", "ubuntu-22.04")
ELIXIR_VERSION = re.compile(r"\d+\.\d+(\.\d+)?")
OTP_VERSION = re.compile(r"\d+(\.\d+){0,3}")

# A mistyped list should fail rather than fan out into a huge matrix.
MAX_CUSTOM_LEGS = 12

# The core job, the plan and the required check, which every run has.
FIXED_JOBS = 3

CORE_JOB = "Core units and package"
PLAN_JOB = "plan"
REQUIRED_JOB = "Required Linux checks"


class PlanError(ValueError):
    """The inputs name a run that cannot or must not happen."""


def version_key(version):
    """Order 3.3 < 3.3a < 3.4, so the first and last entries are the edges."""
    found = re.fullmatch(r"(\d+)\.(\d+)([a-z]?)", version)
    if not found:
        raise PlanError(f"{version!r} is not a tmux release")
    return int(found[1]), int(found[2]), found[3]


def load(path=SUPPORT):
    """Read the support manifest and refuse one that cannot drive a matrix."""
    manifest = json.loads(Path(path).read_text())
    entries = manifest.get("required_linux") or []
    if manifest.get("schema_version") != 1 or not entries:
        raise PlanError("the manifest needs schema_version 1 and required_linux cells")
    names = [entry["tmux"] for entry in entries]
    if manifest.get("tmux_minimum") not in names:
        raise PlanError("missing required tmux floor")
    if [version_key(name) for name in names] != sorted({version_key(name) for name in names}):
        raise PlanError("required_linux must list each release once, oldest first")
    for entry in entries:
        if not FULL_COMMIT.fullmatch(entry.get("source", "")):
            raise PlanError(f"tmux {entry['tmux']} has no full source commit")
    return manifest


def split_list(value):
    """Split a comma-separated input, dropping blanks and repeats."""
    items = []
    for each in value.split(","):
        item = each.strip()
        if item and item not in items:
            items.append(item)
    return items


def resolve_scope(event, scope):
    """Decide how much of the table a run covers."""
    if scope:
        if scope not in SCOPES:
            raise PlanError(f"scope must be one of {', '.join(SCOPES)}, not {scope!r}")
        return scope
    if event in EVENT_SCOPES:
        return EVENT_SCOPES[event]
    raise PlanError(f"no scope is defined for the {event!r} event")


def check_scope_inputs(scope, tmux_ref):
    """Refuse a list of refs that the scope would silently ignore."""
    if tmux_ref and scope != "custom":
        raise PlanError("tmux-ref is only used with scope custom")


def edge_versions(names):
    """Pick the oldest and the newest required release."""
    return list(dict.fromkeys([names[0], names[-1]]))


def custom_refs(tmux_ref):
    """Validate the refs a custom run was asked to build."""
    items = split_list(tmux_ref)
    if not items:
        raise PlanError("scope custom needs tmux-ref, a comma-separated list of tmux refs")
    try:
        return [check_ref(item) for item in items]
    except ValueError as error:
        raise PlanError(str(error)) from error


def select_toolchains(manifest, elixir, otp):
    """The reference pair, or the Elixir and OTP versions a dispatch asked for."""
    elixirs, otps = split_list(elixir), split_list(otp)
    for version in elixirs:
        if not ELIXIR_VERSION.fullmatch(version):
            raise PlanError(f"elixir must name versions such as 1.20.4, not {version!r}")
    for version in otps:
        if not OTP_VERSION.fullmatch(version):
            raise PlanError(f"otp must name versions such as 29.1.2, not {version!r}")
    if not elixirs and not otps:
        return [{"toolchain": "reference", "elixir": "", "otp": ""}]
    return [{"toolchain": "custom", "elixir": e, "otp": o}
            for e in elixirs or [manifest["reference"]["elixir"]]
            for o in otps or [manifest["reference"]["otp"]]]


def choose_image(image):
    """Pick the runner image, which is the one CI always used unless a dispatch asks."""
    if not image:
        return RUNNERS[0]
    if image not in RUNNERS:
        raise PlanError(f"os must be one of {', '.join(RUNNERS)}, not {image!r}")
    return image


def cell(spec, toolchain):
    """Describe one native cell."""
    tmux, source, ref, build = spec
    label = toolchain["toolchain"]
    if label == "custom":
        label += f" (Elixir {toolchain['elixir']}, OTP {toolchain['otp']})"
    return {"name": f"Native tmux {tmux} / {label}", "tmux": tmux, "source": source, "ref": ref,
            "build": build, "toolchain": toolchain["toolchain"], "elixir": toolchain["elixir"],
            "otp": toolchain["otp"], "tmate": "off"}


def custom_specs(manifest, refs):
    """A table release keeps its pinned commit; any other ref is built from the ref."""
    sources = {entry["tmux"]: entry["source"] for entry in manifest["required_linux"]}
    return [(ref, sources[ref], "", "pinned") if ref in sources else (ref, "", ref, "ref") for ref in refs]


def require_cells(cells):
    """Refuse a plan with no cell, which GitHub would reject anyway."""
    if not cells:
        raise PlanError("the plan has no native cell")


def assign_tmate(event, mode, cells):
    """Give exactly one cell the debugging session, or fail."""
    if mode not in TMATE_MODES:
        raise PlanError(f"tmate must be one of {', '.join(TMATE_MODES)}, not {mode!r}")
    if mode == "off":
        return
    if event != "workflow_dispatch":
        raise PlanError("tmate is only available on a workflow_dispatch run")
    if len(cells) != 1:
        raise PlanError(f"tmate needs exactly one cell and this run has {len(cells)}; "
                        "use scope custom with one tmux-ref, elixir and otp")
    cells[0]["tmate"] = mode


def plan(manifest, *, event, scope="", tmux_ref="", elixir="", otp="", image="", tmate=""):
    """Return the matrix, the runner image and the job count for one run."""
    chosen = resolve_scope(event, scope)
    check_scope_inputs(chosen, tmux_ref)
    runner = choose_image(image)
    toolchains = select_toolchains(manifest, elixir, otp)
    entries = manifest["required_linux"]
    names = [entry["tmux"] for entry in entries]

    if chosen == "custom":
        specs = custom_specs(manifest, custom_refs(tmux_ref))
        if len(specs) * len(toolchains) > MAX_CUSTOM_LEGS:
            raise PlanError(f"this run would have {len(specs) * len(toolchains)} cells; "
                            f"at most {MAX_CUSTOM_LEGS} fit a custom run")
    else:
        picked = names if chosen == "full" else edge_versions(names)
        specs = [(entry["tmux"], entry["source"], "", "pinned") for entry in entries if entry["tmux"] in picked]
    cells = [cell(spec, toolchain) for spec in specs for toolchain in toolchains]
    if chosen != "custom" and toolchains[0]["toolchain"] == "reference" and manifest["tracking"]["required"]:
        newest = entries[-1]
        cells.append(cell((newest["tmux"], newest["source"], "", "pinned"),
                          {"toolchain": "tracking", "elixir": "", "otp": ""}))
    require_cells(cells)
    assign_tmate(event, tmate or "off", cells)
    return {"scope": chosen, "os": runner, "matrix": {"include": cells}, "expected_jobs": FIXED_JOBS + len(cells)}


def job_names(result):
    """Name the jobs a plan produces, as the workflow names them."""
    return {CORE_JOB, PLAN_JOB, REQUIRED_JOB, *(each["name"] for each in result["matrix"]["include"])}


def summary(result):
    """Describe a plan for the job summary."""
    lines = [f"### Native plan: {result['scope']}", "",
             f"Expected jobs in this workflow: {result['expected_jobs']}", ""]
    lines += [f"- {each['name']}" for each in result["matrix"]["include"]]
    return "\n".join(lines) + "\n"


def outputs(result):
    """Flatten a plan into single-line workflow outputs."""
    return {"scope": result["scope"], "os": result["os"],
            "matrix": json.dumps(result["matrix"], separators=(",", ":")),
            "expected_jobs": str(result["expected_jobs"])}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    planner = commands.add_parser("plan", help="plan the native cells for one event")
    planner.add_argument("--event", required=True, help="github.event_name")
    planner.add_argument("--scope", default="", help="edges, full or custom")
    planner.add_argument("--tmux-ref", default="", help="comma-separated tmux refs")
    planner.add_argument("--elixir", default="", help="comma-separated Elixir versions")
    planner.add_argument("--otp", default="", help="comma-separated OTP versions")
    planner.add_argument("--os", default="", help="runner image for the native cells")
    planner.add_argument("--tmate", default="", help="off, before-tests or on-failure")
    planner.add_argument("--github-output", type=Path, help="the GITHUB_OUTPUT file")
    planner.add_argument("--summary", type=Path, help="the GITHUB_STEP_SUMMARY file")
    arguments = parser.parse_args(argv)
    try:
        result = plan(load(), event=arguments.event, scope=arguments.scope, tmux_ref=arguments.tmux_ref,
                      elixir=arguments.elixir, otp=arguments.otp, image=arguments.os, tmate=arguments.tmate)
    except PlanError as error:
        print(f"plan: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    if arguments.github_output:
        with arguments.github_output.open("a") as handle:
            for key, value in outputs(result).items():
                handle.write(f"{key}={value}\n")
    if arguments.summary:
        with arguments.summary.open("a") as handle:
            handle.write(summary(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
