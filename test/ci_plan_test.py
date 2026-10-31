"""Prove the CI plan picks what each event should run, and that it can fail.

Every rule has a check, and every check has a deliberate break: the rule is
replaced with its absence and the check has to notice. A check that passes
with its rule removed would prove nothing about the rule.
"""
import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import ci_plan

MANIFEST = ci_plan.load()
ENTRIES = MANIFEST["required_linux"]
NAMES = [entry["tmux"] for entry in ENTRIES]
OLDEST, NEWEST = NAMES[0], NAMES[-1]

# The rules as the module defines them, before any deliberate break.
RULES = {name: getattr(ci_plan, name) for name in ("resolve_scope", "assign_tmate", "select_toolchains")}


def cells(result):
    return result["matrix"]["include"]


def pairs(result):
    return [(each["tmux"], each["toolchain"]) for each in cells(result)]


def run(event, **inputs):
    return ci_plan.plan(MANIFEST, event=event, **inputs)


def refused(test, match, event="workflow_dispatch", **inputs):
    """Fail the check unless the plan is refused with a message naming the problem."""
    try:
        run(event, **inputs)
    except ci_plan.PlanError as error:
        test.assertRegex(str(error), match)
        return
    test.fail(f"the plan was not refused: {match}")


def manifest_with(**changes):
    return {**copy.deepcopy(MANIFEST), **changes}


def loaded(manifest):
    with tempfile.TemporaryDirectory(prefix="libtmux-elixir-plan-") as directory:
        path = Path(directory) / "support.json"
        path.write_text(json.dumps(manifest))
        return ci_plan.load(path)


def check_push_runs_the_edges_only(test):
    result = run("push")
    test.assertEqual(result["scope"], "edges")
    test.assertEqual(pairs(result), [(OLDEST, "reference"), (NEWEST, "reference"), (NEWEST, "tracking")])


def check_pull_request_runs_the_edges_only(test):
    test.assertEqual(pairs(run("pull_request")), [(OLDEST, "reference"), (NEWEST, "reference"), (NEWEST, "tracking")])


def check_dispatch_defaults_to_the_edges(test):
    result = run("workflow_dispatch")
    test.assertEqual(result["scope"], "edges")
    test.assertEqual(pairs(result), pairs(run("push")))


def check_a_schedule_runs_the_full_scope(test):
    test.assertEqual(run("schedule")["scope"], "full")


def check_full_runs_the_whole_table(test):
    result = run("workflow_dispatch", scope="full")
    test.assertEqual(result["scope"], "full")
    test.assertEqual(pairs(result), [*((name, "reference") for name in NAMES), (NEWEST, "tracking")])
    test.assertEqual([each["source"] for each in cells(result)[:-1]], [entry["source"] for entry in ENTRIES])


def check_an_explicit_scope_beats_the_event(test):
    test.assertEqual(run("push", scope="full")["scope"], "full")
    test.assertEqual(run("pull_request", scope="custom", tmux_ref="master")["scope"], "custom")


def check_the_manifest_alone_decides_the_table(test):
    manifest = manifest_with(required_linux=[*ENTRIES, {"tmux": "3.9", "source": "a" * 40}])
    test.assertEqual(pairs(ci_plan.plan(manifest, event="push")),
                     [(OLDEST, "reference"), ("3.9", "reference"), ("3.9", "tracking")])


def check_a_single_cell_is_one_edge(test):
    manifest = manifest_with(required_linux=ENTRIES[:1], tmux_minimum=OLDEST)
    test.assertEqual(pairs(ci_plan.plan(manifest, event="push")), [(OLDEST, "reference"), (OLDEST, "tracking")])


def check_the_tracking_toolchain_is_optional_in_the_manifest(test):
    manifest = manifest_with(tracking={"source": ".tool-versions", "required": False})
    test.assertEqual(pairs(ci_plan.plan(manifest, event="push")), [(OLDEST, "reference"), (NEWEST, "reference")])


def check_a_scope_must_be_known(test):
    refused(test, "scope must be one of", scope="everything")


def check_an_unknown_event_is_refused(test):
    refused(test, "no scope is defined", event="release")


def check_a_ref_list_needs_the_custom_scope(test):
    refused(test, "only used with scope custom", scope="edges", tmux_ref="master")
    refused(test, "only used with scope custom", tmux_ref="master")


def check_a_custom_run_needs_refs(test):
    refused(test, "needs tmux-ref", scope="custom")
    refused(test, "needs tmux-ref", scope="custom", tmux_ref=" , ")


def check_every_ref_is_validated(test):
    for ref in ("3.6b;id", "-upload-pack=x", "a b", "$(id)", "a..b", "a1b2c3d", "topic/", "x.lock"):
        refused(test, "tmux ref", scope="custom", tmux_ref=f"master,{ref}")


def check_too_many_cells_are_refused(test):
    refs = ",".join(f"topic-{number}" for number in range(ci_plan.MAX_CUSTOM_LEGS + 1))
    refused(test, "at most", scope="custom", tmux_ref=refs)
    refused(test, "at most", scope="custom", tmux_ref="a,b,c,d", elixir="1.19.5,1.20.4", otp="28.3,29.1.2")


def check_custom_names_resolve_to_their_build(test):
    sha = "a" * 40
    result = run("workflow_dispatch", scope="custom", tmux_ref=f"{OLDEST}, master,{sha},{OLDEST}")
    by_tmux = {each["tmux"]: each for each in cells(result)}
    test.assertEqual(list(by_tmux), [OLDEST, "master", sha])
    test.assertEqual((by_tmux[OLDEST]["build"], by_tmux[OLDEST]["source"], by_tmux[OLDEST]["ref"]),
                     ("pinned", ENTRIES[0]["source"], ""))
    test.assertEqual((by_tmux["master"]["build"], by_tmux["master"]["source"], by_tmux["master"]["ref"]),
                     ("ref", "", "master"))
    test.assertEqual(by_tmux[sha]["build"], "ref")
    test.assertEqual({each["toolchain"] for each in cells(result)}, {"reference"})
    test.assertEqual(by_tmux["master"]["name"], "Native tmux master / reference")


def check_stack_inputs_replace_the_toolchains(test):
    result = run("workflow_dispatch", elixir="1.19.5", otp="28.3")
    test.assertEqual(pairs(result), [(OLDEST, "custom"), (NEWEST, "custom")])
    test.assertEqual({(each["elixir"], each["otp"]) for each in cells(result)}, {("1.19.5", "28.3")})
    only_otp = run("workflow_dispatch", scope="custom", tmux_ref="master", otp="28.3")
    test.assertEqual([(each["elixir"], each["otp"]) for each in cells(only_otp)],
                     [(MANIFEST["reference"]["elixir"], "28.3")])
    both = run("workflow_dispatch", scope="custom", tmux_ref="master", elixir="1.19.5,1.20.4", otp="28.3,29.1.2")
    test.assertEqual(len(cells(both)), 4)
    test.assertEqual(cells(result)[0]["name"], f"Native tmux {OLDEST} / custom (Elixir 1.19.5, OTP 28.3)")


def check_an_unusable_stack_version_is_refused(test):
    refused(test, "elixir must name versions", elixir="latest")
    refused(test, "otp must name versions", otp="29;id")


def check_the_runner_is_chosen_from_the_images(test):
    test.assertEqual(run("push")["os"], ci_plan.RUNNERS[0])
    test.assertEqual(run("workflow_dispatch", image="ubuntu-latest")["os"], "ubuntu-latest")
    refused(test, "os must be one of", image="macos-latest")


def check_one_cell_gets_the_debug_session(test):
    for mode in ("before-tests", "on-failure"):
        result = run("workflow_dispatch", scope="custom", tmux_ref="master", tmate=mode)
        test.assertEqual([each["tmate"] for each in cells(result)], [mode])


def check_no_debug_session_by_default(test):
    for result in (run("push"), run("workflow_dispatch", scope="full"),
                   run("workflow_dispatch", scope="custom", tmux_ref="master", tmate="off")):
        test.assertEqual({each["tmate"] for each in cells(result)}, {"off"})


def check_several_cells_cannot_share_a_debug_session(test):
    refused(test, "exactly one cell", tmate="on-failure")
    refused(test, "exactly one cell", scope="full", tmate="before-tests")
    refused(test, "exactly one cell", scope="custom", tmux_ref="master,3.8", tmate="on-failure")
    refused(test, "exactly one cell", scope="custom", tmux_ref="master", elixir="1.19.5,1.20.4", tmate="on-failure")


def check_a_debug_session_needs_a_dispatch(test):
    for event in ("push", "pull_request"):
        refused(test, "only available on a workflow_dispatch", event=event, scope="custom",
                tmux_ref="master", tmate="on-failure")


def check_a_debug_mode_must_be_known(test):
    refused(test, "tmate must be one of", scope="custom", tmux_ref="master", tmate="always")


def check_the_job_count_adds_up(test):
    for result in (run("push"), run("workflow_dispatch", scope="full"),
                   run("workflow_dispatch", scope="custom", tmux_ref="master,3.8")):
        test.assertEqual(result["expected_jobs"], len(cells(result)) + 3)
        test.assertEqual(len(ci_plan.job_names(result)), result["expected_jobs"])
    test.assertEqual(run("push")["expected_jobs"], 6)


def check_the_matrix_is_never_empty(test):
    with test.assertRaisesRegex(ci_plan.PlanError, "no native cell"):
        ci_plan.require_cells([])


def check_the_manifest_must_be_consistent(test):
    with test.assertRaisesRegex(ci_plan.PlanError, "missing required tmux floor"):
        loaded(manifest_with(tmux_minimum="3.2a"))
    with test.assertRaisesRegex(ci_plan.PlanError, "schema_version 1"):
        loaded(manifest_with(required_linux=[]))
    with test.assertRaisesRegex(ci_plan.PlanError, "oldest first"):
        loaded(manifest_with(required_linux=list(reversed(ENTRIES))))
    with test.assertRaisesRegex(ci_plan.PlanError, "oldest first"):
        loaded(manifest_with(required_linux=[ENTRIES[0], ENTRIES[0]]))
    with test.assertRaisesRegex(ci_plan.PlanError, "full source commit"):
        loaded(manifest_with(required_linux=[{"tmux": OLDEST, "source": "87fe00e"}, *ENTRIES[1:]]))
    test.assertEqual(loaded(copy.deepcopy(MANIFEST)), MANIFEST)


def every_name(names):
    return list(names)


def hard_coded_edges(names):
    return [OLDEST, NEWEST]


def pull_requests_run_everything(event, scope):
    return "full" if event == "pull_request" else RULES["resolve_scope"](event, scope)


def schedules_run_the_edges(event, scope):
    return "edges" if event == "schedule" else RULES["resolve_scope"](event, scope)


def ignoring_the_given_scope(event, scope):
    return RULES["resolve_scope"](event, "")


def always_full(event, scope):
    return "full" if not scope else scope


def unchecked_scope(event, scope):
    return scope or "edges"


def unchecked_event(event, scope):
    return scope if scope in ci_plan.SCOPES else "edges"


def custom_without_a_requirement(tmux_ref):
    return ci_plan.split_list(tmux_ref) or ["master"]


def unvalidated(ref):
    return ref


def ignored(*arguments):
    return None


def always_ref(manifest, refs):
    return [(ref, "", ref, "ref") for ref in refs]


def always_pinned(manifest, refs):
    return [(ref, "x" * 40, "", "pinned") for ref in refs]


def reference_only(manifest, elixir, otp):
    return [{"toolchain": "reference", "elixir": "", "otp": ""}]


def unchecked_versions(manifest, elixir, otp):
    chosen_elixir, chosen_otp = ci_plan.split_list(elixir), ci_plan.split_list(otp)
    if not chosen_elixir and not chosen_otp:
        return RULES["select_toolchains"](manifest, elixir, otp)
    return [{"toolchain": "custom", "elixir": e, "otp": o}
            for e in chosen_elixir or ["1.20.4"] for o in chosen_otp or ["29.1.2"]]


def default_image(image):
    return ci_plan.RUNNERS[0]


def any_image(image):
    return image or ci_plan.RUNNERS[0]


def debug_session_everywhere(event, mode, got_cells):
    for each in got_cells:
        each["tmate"] = mode


def debug_session_without_event(event, mode, got_cells):
    RULES["assign_tmate"]("workflow_dispatch", mode, got_cells)


def debug_session_on_the_first_cell(event, mode, got_cells):
    if mode != "off":
        got_cells[0]["tmate"] = mode


def unchecked_mode(event, mode, got_cells):
    if mode in ci_plan.TMATE_MODES:
        RULES["assign_tmate"](event, mode, got_cells)
    elif len(got_cells) == 1:
        got_cells[0]["tmate"] = mode


def trusting_load(path=ci_plan.SUPPORT):
    return json.loads(Path(path).read_text())


DELIBERATE_BREAKS = [
    ("the edges rule takes every release", "edge_versions", every_name, check_push_runs_the_edges_only),
    ("the edges are written into the plan", "edge_versions", hard_coded_edges,
     check_the_manifest_alone_decides_the_table),
    ("a pull request runs the full scope", "resolve_scope", pull_requests_run_everything,
     check_pull_request_runs_the_edges_only),
    ("a dispatch ignores the scope it was given", "resolve_scope", ignoring_the_given_scope,
     check_full_runs_the_whole_table),
    ("a given scope loses to the event", "resolve_scope", ignoring_the_given_scope,
     check_an_explicit_scope_beats_the_event),
    ("a dispatch does not default to the edges", "resolve_scope", always_full,
     check_dispatch_defaults_to_the_edges),
    ("a schedule runs the edges", "resolve_scope", schedules_run_the_edges, check_a_schedule_runs_the_full_scope),
    ("an unknown scope is accepted", "resolve_scope", unchecked_scope, check_a_scope_must_be_known),
    ("an unknown event is accepted", "resolve_scope", unchecked_event, check_an_unknown_event_is_refused),
    ("refs the scope ignores are accepted", "check_scope_inputs", ignored, check_a_ref_list_needs_the_custom_scope),
    ("a custom run without refs is planned", "custom_refs", custom_without_a_requirement,
     check_a_custom_run_needs_refs),
    ("a ref is not validated", "check_ref", unvalidated, check_every_ref_is_validated),
    ("the cell count is unlimited", "MAX_CUSTOM_LEGS", 1000, check_too_many_cells_are_refused),
    ("a custom ref is always built from source", "custom_specs", always_ref,
     check_custom_names_resolve_to_their_build),
    ("a custom ref is always pinned", "custom_specs", always_pinned, check_custom_names_resolve_to_their_build),
    ("the stack inputs are ignored", "select_toolchains", reference_only, check_stack_inputs_replace_the_toolchains),
    ("an unusable stack version is accepted", "select_toolchains", unchecked_versions,
     check_an_unusable_stack_version_is_refused),
    ("the os input is ignored", "choose_image", default_image, check_the_runner_is_chosen_from_the_images),
    ("an unknown os is accepted", "choose_image", any_image, check_the_runner_is_chosen_from_the_images),
    ("no cell gets the debug session", "assign_tmate", ignored, check_one_cell_gets_the_debug_session),
    ("every cell gets the debug session", "assign_tmate", debug_session_everywhere,
     check_several_cells_cannot_share_a_debug_session),
    ("the debug session lands on the first of many cells", "assign_tmate", debug_session_on_the_first_cell,
     check_several_cells_cannot_share_a_debug_session),
    ("the debug session runs outside a dispatch", "assign_tmate", debug_session_without_event,
     check_a_debug_session_needs_a_dispatch),
    ("an unknown debug mode is accepted", "assign_tmate", unchecked_mode, check_a_debug_mode_must_be_known),
    ("the job count omits the fixed jobs", "FIXED_JOBS", 0, check_the_job_count_adds_up),
    ("an empty matrix is emitted", "require_cells", ignored, check_the_matrix_is_never_empty),
    ("the job names omit the matrix", "job_names", lambda result: {"plan"}, check_the_job_count_adds_up),
    ("a manifest that cannot drive a matrix is trusted", "load", trusting_load, check_the_manifest_must_be_consistent),
]

ALL_CHECKS = [
    check_push_runs_the_edges_only,
    check_pull_request_runs_the_edges_only,
    check_dispatch_defaults_to_the_edges,
    check_a_schedule_runs_the_full_scope,
    check_full_runs_the_whole_table,
    check_an_explicit_scope_beats_the_event,
    check_the_manifest_alone_decides_the_table,
    check_a_single_cell_is_one_edge,
    check_the_tracking_toolchain_is_optional_in_the_manifest,
    check_a_scope_must_be_known,
    check_an_unknown_event_is_refused,
    check_a_ref_list_needs_the_custom_scope,
    check_a_custom_run_needs_refs,
    check_every_ref_is_validated,
    check_too_many_cells_are_refused,
    check_custom_names_resolve_to_their_build,
    check_stack_inputs_replace_the_toolchains,
    check_an_unusable_stack_version_is_refused,
    check_the_runner_is_chosen_from_the_images,
    check_one_cell_gets_the_debug_session,
    check_no_debug_session_by_default,
    check_several_cells_cannot_share_a_debug_session,
    check_a_debug_session_needs_a_dispatch,
    check_a_debug_mode_must_be_known,
    check_the_job_count_adds_up,
    check_the_matrix_is_never_empty,
    check_the_manifest_must_be_consistent,
]

# Checks that state a default or a boundary no single removal can reach.
WITHOUT_A_BREAK = {
    check_no_debug_session_by_default,
    check_a_single_cell_is_one_edge,
    check_the_tracking_toolchain_is_optional_in_the_manifest,
}


class PlanFollowsItsRules(unittest.TestCase):
    def test_every_check_passes(self):
        for check in ALL_CHECKS:
            with self.subTest(check=check.__name__):
                check(self)

    def test_every_check_has_a_deliberate_break(self):
        broken = {each[3] for each in DELIBERATE_BREAKS}
        self.assertEqual({check for check in ALL_CHECKS if check not in broken}, WITHOUT_A_BREAK)

    def test_a_check_fails_when_its_rule_is_removed(self):
        for description, attribute, replacement, check in DELIBERATE_BREAKS:
            with self.subTest(description):
                check(self)
                with mock.patch.object(ci_plan, attribute, replacement):
                    with self.assertRaises(AssertionError):
                        check(self)


class PlanCommand(unittest.TestCase):
    def main(self, *arguments):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                status = ci_plan.main(list(arguments))
            except SystemExit as error:
                status = error.code
        return status, out.getvalue(), err.getvalue()

    def test_the_outputs_are_single_line_json(self):
        with tempfile.TemporaryDirectory(prefix="libtmux-elixir-plan-") as directory:
            output, summary = Path(directory) / "output", Path(directory) / "summary"
            status, printed, _ = self.main("plan", "--event", "push", "--github-output", str(output),
                                           "--summary", str(summary))
            self.assertEqual(status, 0)
            self.assertEqual(json.loads(printed)["scope"], "edges")
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(set(lines), {"scope", "os", "matrix", "expected_jobs"})
            self.assertEqual(json.loads(lines["matrix"]), run("push")["matrix"])
            self.assertEqual(lines["expected_jobs"], str(run("push")["expected_jobs"]))
            self.assertIn(f"Native tmux {NEWEST} / tracking", summary.read_text())

    def test_a_refused_plan_exits_nonzero_and_writes_nothing(self):
        with tempfile.TemporaryDirectory(prefix="libtmux-elixir-plan-") as directory:
            output = Path(directory) / "output"
            status, printed, error = self.main("plan", "--event", "push", "--tmux-ref", "master",
                                               "--github-output", str(output))
            self.assertEqual((status, printed), (1, ""))
            self.assertIn("only used with scope custom", error)
            self.assertFalse(output.exists())

    def test_the_inputs_reach_the_plan(self):
        status, printed, _ = self.main("plan", "--event", "workflow_dispatch", "--scope", "custom",
                                       "--tmux-ref", "master", "--elixir", "1.19.5", "--otp", "28.3",
                                       "--os", "ubuntu-latest", "--tmate", "on-failure")
        result = json.loads(printed)
        self.assertEqual(status, 0)
        self.assertEqual(result["os"], "ubuntu-latest")
        self.assertEqual([(each["elixir"], each["otp"], each["tmate"]) for each in cells(result)],
                         [("1.19.5", "28.3", "on-failure")])


if __name__ == "__main__":
    unittest.main()
