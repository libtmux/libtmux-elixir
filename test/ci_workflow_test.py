"""Prove scaffold.yml takes its cells from the plan and stays bound to the release.

The workflows are read as text, because the job that runs these tests has no
YAML parser. Each rule has a mutation that has to be reported.
"""
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import ci_plan

SCAFFOLD = (ROOT / ".github/workflows/scaffold.yml").read_text()
RELEASE = (ROOT / ".github/workflows/release.yml").read_text()
MANIFEST = ci_plan.load()


def split_jobs(text):
    """Map each job id to its text."""
    _, _, body = text.partition("\njobs:\n")
    found, name = {}, None
    for line in body.splitlines():
        header = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if header:
            name = header.group(1)
            found[name] = []
        elif name and (line.startswith("    ") or not line.strip()):
            found[name].append(line)
        elif line and not line.startswith((" ", "#")):
            name = None
    return {key: "\n".join(value) for key, value in found.items()}


def field(job, key):
    match = re.search(rf"^    {re.escape(key)}: (.*)$", job, re.MULTILINE)
    return match.group(1).strip() if match else None


def dispatch_inputs(text):
    """Map each workflow_dispatch input to its text."""
    match = re.search(r"(?ms)^  workflow_dispatch:\n    inputs:\n(.*?)^  workflow_call:", text)
    found, name = {}, None
    for line in (match[1] if match else "").splitlines():
        header = re.match(r"^      ([a-z-]+):\s*$", line)
        if header:
            name = header.group(1)
            found[name] = []
        elif name:
            found[name].append(line)
    return {key: "\n".join(value) for key, value in found.items()}


def options(text):
    match = re.search(r"options: \[(.*?)\]", text)
    return [each.strip() for each in match[1].split(",")] if match else None


def needs_of(job):
    return re.findall(r"[A-Za-z0-9_-]+", (field(job, "needs") or "").strip("[]"))


def problems(scaffold, release):
    """Name each way the workflows stop following the plan."""
    found = []
    jobs = split_jobs(scaffold)
    code = re.sub(r"(?m)^ +description: .*\n(?: {10,}.*\n)*", "", scaffold)
    for entry in MANIFEST["required_linux"]:
        for token in (entry["tmux"], entry["source"]):
            if re.search(rf"(?<![\w.]){re.escape(token)}(?![\w.])", code):
                found.append(f"scaffold.yml names tmux {entry['tmux']}, which only the manifest may")
    if re.search(r"(?m)^\s+include:", scaffold) or "required_linux" in code:
        found.append("scaffold.yml lists its own matrix")
    if not {"scaffold", "plan", "native", "required-linux"} <= set(jobs):
        return [*found, "scaffold.yml needs scaffold, plan, native and required-linux jobs"]

    native = jobs["native"]
    if needs_of(native) != ["plan"]:
        found.append("native: must wait for the plan")
    if field(native, "runs-on") != "${{ needs.plan.outputs.os }}":
        found.append("native: must run on the image the plan chose")
    if "matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}" not in native:
        found.append("native: the matrix must come from the plan")
    if re.search(r"(?m)^    if:", native):
        found.append("native: the matrix shrinks through the plan, never an if on the job")
    if field(native, "name") != "${{ matrix.name }}":
        found.append("native: the job name comes from the plan")

    gate = jobs["required-linux"]
    if field(gate, "name") != "Required Linux checks":
        found.append("required-linux: keeps its name, Required Linux checks")
    if field(gate, "if") != "always()":
        found.append("required-linux: must run when a job it waits for failed")
    waited = needs_of(gate)
    if set(waited) != set(jobs) - {"required-linux"}:
        found.append("required-linux: must wait for every other job")
    for job in waited:
        variable = {"plan": "PLAN_RESULT", "scaffold": "CORE_RESULT", "native": "NATIVE_RESULT"}.get(job, f"{job.upper()}_RESULT")
        if f"{variable}: ${{{{ needs.{job}.result }}}}" not in gate or f'test "${variable}" = success' not in gate:
            found.append(f"required-linux: must require {job} to have succeeded")

    group = re.search(r"(?m)^concurrency:\n  group: (.*)\n  cancel-in-progress: (.*)$", scaffold)
    if not group or "github.event_name == 'workflow_dispatch' && github.run_id ||" not in group[1]:
        found.append("a dispatch run must have its own concurrency group")
    if not group or "|| github.ref" not in group[1] or group[2] != "true":
        found.append("a push and a pull request must still cancel the run they supersede")

    inputs = dispatch_inputs(scaffold)
    if sorted(inputs) != ["elixir", "os", "otp", "scope", "tmux-ref"]:
        found.append("the dispatch inputs are not the plan's")
    if options(inputs.get("scope", "")) != list(ci_plan.SCOPES) or "default: edges" not in inputs.get("scope", ""):
        found.append("the scope input must offer exactly the plan's scopes and default to edges")
    if options(inputs.get("os", "")) != list(ci_plan.RUNNERS):
        found.append("the os input must offer exactly the plan's runner images")
    if re.search(r"macos", scaffold, re.IGNORECASE):
        found.append("scaffold.yml must not run on macOS")
    for name in inputs:
        if f"inputs.{name} }}}}" not in jobs["plan"]:
            found.append(f"plan: the {name} input must reach the plan")
    for line in scaffold.splitlines():
        if "inputs." in line and not re.fullmatch(r"\s+[A-Z_]+: \$\{\{ inputs\.[a-z-]+ \}\}", line):
            found.append("an input may reach a step only through env")
    call = re.search(r"(?ms)^  workflow_call:\n    inputs:\n      scope:\n(.*?)^\S", scaffold + "\n_")
    if not call or "required: true" not in call[1]:
        found.append("the workflow_call scope input must be required")
    if "unittest discover -s test -p 'ci_*_test.py'" not in jobs["scaffold"]:
        found.append("scaffold: must run the CI plan and workflow tests")

    verify = split_jobs(release).get("verify", "")
    if "uses: ./.github/workflows/scaffold.yml" not in verify:
        found.append("release: verify must call scaffold.yml")
    if not re.search(r"(?m)^    with:\n      scope: full$", verify):
        found.append("release: verify must ask for scope full")
    if needs_of(split_jobs(release).get("publish", "")) != ["verify"]:
        found.append("release: publish must wait for verify")
    return found


def replaced(text, old, new):
    assert old in text, old
    return text.replace(old, new, 1)


def without(text, line):
    return replaced(text, line, "")


MUTATIONS = [
    ("a tmux version returns to the workflow", lambda s, r: (s + f"      - run: echo {ci_plan.load()['required_linux'][1]['tmux']}\n", r),
     "scaffold.yml names tmux"),
    ("a source commit returns to the workflow", lambda s, r: (s + f"      - run: echo {ci_plan.load()['required_linux'][0]['source']}\n", r),
     "scaffold.yml names tmux"),
    ("the matrix is listed again", lambda s, r: (replaced(
        s, "      matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}",
        "      matrix:\n        include:\n          - {name: x}"), r), "scaffold.yml lists its own matrix"),
    ("native stops waiting for the plan", lambda s, r: (replaced(s, "    needs: plan\n", ""), r), "native: must wait for the plan"),
    ("native runs on a fixed image", lambda s, r: (replaced(
        s, "runs-on: ${{ needs.plan.outputs.os }}", "runs-on: ubuntu-24.04"), r), "the image the plan chose"),
    ("native reads another output", lambda s, r: (replaced(
        s, "fromJSON(needs.plan.outputs.matrix)", "fromJSON(needs.plan.outputs.other)"), r), "the matrix must come from the plan"),
    ("native is trimmed with an if", lambda s, r: (replaced(
        s, "    needs: plan\n    runs-on:", "    needs: plan\n    if: github.event_name != 'push'\n    runs-on:"), r),
     "never an if on the job"),
    ("native names itself", lambda s, r: (replaced(s, "    name: ${{ matrix.name }}\n", "    name: Native\n"), r), "the job name comes from the plan"),
    ("the aggregate is renamed", lambda s, r: (replaced(s, "name: Required Linux checks", "name: Checks"), r), "keeps its name"),
    ("the aggregate is skipped after a failure", lambda s, r: (replaced(
        s, "    if: always()\n", ""), r), "must run when a job it waits for failed"),
    ("the aggregate forgets the plan", lambda s, r: (replaced(
        s, "needs: [plan, scaffold, native]", "needs: [scaffold, native]"), r), "must wait for every other job"),
    ("the aggregate stops testing the plan", lambda s, r: (without(
        s, '          test "$PLAN_RESULT" = success\n'), r), "must require plan to have succeeded"),
    ("the aggregate stops testing the cells", lambda s, r: (without(
        s, '          test "$NATIVE_RESULT" = success\n'), r), "must require native to have succeeded"),
    ("a job is added that the aggregate does not wait for", lambda s, r: (
        s + "\n  extra:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: 'true'\n", r), "must wait for every other job"),
    ("a dispatch shares its group with the push", lambda s, r: (replaced(
        s, "github.event_name == 'workflow_dispatch' && github.run_id || ", ""), r),
     "a dispatch run must have its own concurrency group"),
    ("a push no longer cancels its predecessor", lambda s, r: (replaced(
        s, "cancel-in-progress: true", "cancel-in-progress: false"), r),
     "must still cancel the run they supersede"),
    ("a pull request shares one group with every other", lambda s, r: (replaced(
        s, "github.run_id || github.ref", "github.run_id"), r),
     "must still cancel the run they supersede"),
    ("an input is dropped from the dispatch", lambda s, r: (replaced(
        s, "      otp:\n", "      other:\n"), r), "the dispatch inputs are not the plan's"),
    ("the scope input defaults to full", lambda s, r: (replaced(
        s, "        default: edges\n", "        default: full\n"), r), "default to edges"),
    ("the scope input offers another scope", lambda s, r: (replaced(
        s, "options: [edges, full, custom]", "options: [edges, full]"), r), "the plan's scopes"),
    ("the os input offers another image", lambda s, r: (replaced(
        s, "options: [ubuntu-24.04, ubuntu-latest, ubuntu-22.04]", "options: [ubuntu-24.04]"), r), "the plan's runner images"),
    ("a macOS image appears", lambda s, r: (replaced(s, "ubuntu-22.04]", "ubuntu-22.04, macos-latest]"), r), "must not run on macOS"),
    ("an input stops reaching the plan", lambda s, r: (without(
        s, "          OTP: ${{ inputs.otp }}\n"), r), "plan: the otp input must reach the plan"),
    ("an input is used inline in a script", lambda s, r: (replaced(
        s, '            --elixir "$ELIXIR" \\\n', '            --elixir "${{ inputs.elixir }}" \\\n'), r), "only through env"),
    ("the workflow_call scope is optional", lambda s, r: (replaced(
        s, "        required: true\n", "        required: false\n"), r), "scope input must be required"),
    ("the plan tests stop running", lambda s, r: (replaced(
        s, "unittest discover -s test -p 'ci_*_test.py'", "unittest discover -s test -p 'none_*_test.py'"), r), "must run the CI plan and workflow tests"),
    ("the release stops calling scaffold", lambda s, r: (s, replaced(
        r, "uses: ./.github/workflows/scaffold.yml", "uses: ./.github/workflows/docs.yml")), "verify must call scaffold.yml"),
    ("the release asks for the edges", lambda s, r: (s, replaced(r, "      scope: full", "      scope: edges")), "ask for scope full"),
    ("the release passes no scope", lambda s, r: (s, without(r, "    with:\n      scope: full\n")), "ask for scope full"),
    ("the upload stops waiting for verification", lambda s, r: (s, replaced(r, "    needs: verify\n", "")), "publish must wait for verify"),
]


class WorkflowFollowsThePlan(unittest.TestCase):
    def test_the_workflows_follow_the_plan(self):
        self.assertEqual(problems(SCAFFOLD, RELEASE), [])

    def test_a_mutation_is_reported(self):
        for description, mutate, message in MUTATIONS:
            with self.subTest(description):
                reported = problems(*mutate(SCAFFOLD, RELEASE))
                self.assertTrue([each for each in reported if message in each], (message, reported))

    def test_the_cell_names_follow_the_plan(self):
        self.assertEqual(field(split_jobs(SCAFFOLD)["native"], "name"), "${{ matrix.name }}")
        names = {each["name"] for each in ci_plan.plan(MANIFEST, event="push")["matrix"]["include"]}
        self.assertEqual(names, {f"Native tmux {ci_plan.edge_versions([e['tmux'] for e in MANIFEST['required_linux']])[0]} / reference",
                                 f"Native tmux {MANIFEST['required_linux'][-1]['tmux']} / reference",
                                 f"Native tmux {MANIFEST['required_linux'][-1]['tmux']} / tracking"})
        self.assertEqual(field(split_jobs(SCAFFOLD)["scaffold"], "name"), ci_plan.CORE_JOB)
        self.assertEqual(field(split_jobs(SCAFFOLD)["required-linux"], "name"), ci_plan.REQUIRED_JOB)


if __name__ == "__main__":
    unittest.main()
