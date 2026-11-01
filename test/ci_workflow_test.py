"""Prove scaffold.yml takes its cells from the plan and stays bound to the release.

The workflows are read as text, because the job that runs these tests has no
YAML parser. Each rule has a mutation that has to be reported. A run script
that calls apt or apt-get directly is reported too: only scripts/apt-get.sh
bounds a hung mirror.
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


# What GitHub reads a value as when YAML 1.1 sees it bare.
YAML_BOOLEANS = {**dict.fromkeys(("y", "yes", "true", "on"), "true"),
                 **dict.fromkeys(("n", "no", "false", "off"), "false")}


def options(text):
    match = re.search(r"options: \[(.*?)\]", text)
    return [each.strip().strip("'\"") for each in match[1].split(",")] if match else None


def bare_boolean(token):
    """The boolean YAML 1.1 reads `token` as, or None when it is quoted or not one."""
    token = token.strip()
    if token[:1] in "'\"":
        return None
    return YAML_BOOLEANS.get(token.lower())


def dispatch_booleans(text):
    """Each input default or option that YAML 1.1 reads as a boolean, in a flow or a block list.

    GitHub reads a workflow as YAML 1.1, where a bare off is false. An option list
    then holds a boolean and the string default is no longer among the choices, so
    every dispatch that sets nothing is refused. The test job has no YAML 1.1
    parser, so this reads the lines of each input.
    """
    found = []
    for name, body in dispatch_inputs(text).items():
        in_options = False
        for line in body.splitlines():
            stripped = line.split(" #", 1)[0].rstrip()
            if not stripped.strip():
                continue
            item = re.match(r"\s*-\s+(.+)$", stripped)
            flow = re.match(r"\s*options:\s*\[(.*)\]$", stripped)
            if in_options and item:
                values = [item[1]]
            elif flow:
                values, in_options = flow[1].split(","), False
            else:
                values, in_options = [], stripped.strip() == "options:"
            found += [(name, "option", value.strip(), truth) for value in values if (truth := bare_boolean(value))]
            default = re.match(r"\s*default:\s*(.+)$", stripped)
            if default and (truth := bare_boolean(default[1])):
                found.append((name, "default", default[1].strip(), truth))
    return found


def needs_of(job):
    return re.findall(r"[A-Za-z0-9_-]+", (field(job, "needs") or "").strip("[]"))


TMATE = "mxschmitt/action-tmate"


def steps_of(job):
    """Split a job's text into its steps."""
    return re.split(r"(?m)^(?=      - )", job)[1:]


def step_field(step, key):
    match = re.search(rf"(?m)^        {re.escape(key)}: (.*)$", step)
    return match[1].strip() if match else None


def session_problems(scaffold, release):
    """Name what makes a debugging session unsafe or misplaced."""
    found = []
    jobs = split_jobs(scaffold)
    sessions = 0
    for name, job in jobs.items():
        for step in steps_of(job):
            if TMATE not in step:
                continue
            sessions += 1
            if name != "native":
                found.append(f"{name}: a debugging session belongs only in the native job")
            if not re.search(rf"uses: {re.escape(TMATE)}@[0-9a-f]{{40}} # v", step):
                found.append("a debugging session must be pinned to a full commit SHA")
            if "limit-access-to-actor: true" not in step:
                found.append("a debugging session must be limited to the actor")
            if not step_field(step, "timeout-minutes"):
                found.append("a debugging session needs its own time limit")
            condition = step_field(step, "if") or ""
            if "github.event_name == 'workflow_dispatch'" not in condition or "matrix.tmate ==" not in condition:
                found.append("a debugging session runs only on a dispatch, on the cell the plan chose")
    if sessions != 2:
        found.append("the native job must offer a session before the tests and one after a failure")
    if field(jobs.get("native", ""), "timeout-minutes") != "${{ matrix.tmate == 'off' && 5 || 60 }}":
        found.append("native: the job must cap its time and give the debugging cell more")
    inputs = dispatch_inputs(scaffold)
    if options(inputs.get("tmate", "")) != list(ci_plan.TMATE_MODES) or "default: 'off'" not in inputs.get("tmate", ""):
        found.append("the tmate input must offer exactly the plan's modes and default to off")
    if "TMATE: ${{ inputs.tmate }}" not in jobs.get("plan", "") or '--tmate "$TMATE"' not in jobs.get("plan", ""):
        found.append("plan: must pass the tmate input through env")
    if TMATE in release:
        found.append("release: a release never opens a debugging session")
    return found


# apt or apt-get as a command word: at the start of a line, after a shell
# separator, or after sudo, timeout and the like with their options.
RAW_APT = re.compile(
    r"(?:^|[;&|(!`]|\b(?:sudo|timeout|time|env|exec|xargs|nice|then|do|else))\s*"
    r"(?:(?:-\S+|\d+|\w+=\S*)\s+)*(apt(?:-get)?)(?![\w./-])"
)


def run_scripts(text):
    """Each `run:` value as (job, step label, script), read without a YAML parser.

    A value is the text after `run:` plus the lines indented deeper than its key,
    which covers block scalars and folded plain scalars.
    """
    lines = text.splitlines()
    found, job, in_jobs = [], None, False
    for number, line in enumerate(lines):
        if line and not line.startswith((" ", "#")):
            in_jobs, job = line.startswith("jobs:"), None
        header = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if in_jobs and header:
            job = header[1]
        key = re.match(r"^( *)(- )?run:[ \t]*(.*)$", line)
        if not key:
            continue
        depth = len(key[1]) + (2 if key[2] else 0)
        value = key[3].strip()
        body = [] if value[:1] in ("|", ">") else [value.lstrip("'\"")]
        for rest in lines[number + 1:]:
            if rest.strip() and len(rest) - len(rest.lstrip()) <= depth:
                break
            body.append(rest)
        start = number
        while start > 0 and not re.match(rf"^ {{{depth - 2}}}- ", lines[start]):
            start -= 1
        name = re.search(rf"(?m)^ {{{depth - 2}}}(?:- |  )name:\s*(.*)$", "\n".join(lines[start:number + 1]))
        title = name[1].strip().strip("'\"") if name else None
        found.append((job, f'step "{title}"' if title else f"the step at line {start + 1}", "\n".join(body)))
    return found


def apt_problems(sources):
    """Name each run script that calls apt or apt-get without scripts/apt-get.sh.

    `sources` maps a path to the text of a workflow or composite action. The
    wrapper bounds a hung apt-get only while every call uses it
    (https://github.com/actions/runner-images/issues/15040).
    """
    found = []
    for path, text in sources.items():
        for job, step, script in run_scripts(text):
            for line in script.splitlines():
                call = None if line.lstrip().startswith("#") else RAW_APT.search(line)
                if call:
                    where = f"job {job}, {step}" if job else step
                    found.append(f"{path}: {where}: `{line.strip()}` calls {call[1]} directly; run it through scripts/apt-get.sh")
    return found


def ci_sources():
    """Map the path of each workflow and composite action to its text."""
    paths = [*sorted(ROOT.glob(".github/workflows/*.y*ml")), *sorted(ROOT.glob(".github/actions/*/action.y*ml"))]
    return {str(path.relative_to(ROOT)): path.read_text() for path in paths}


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
    for name, kind, value, truth in dispatch_booleans(scaffold):
        found.append(f"the {name} input has a bare {value} as its {kind}, which GitHub reads as the boolean {truth}; quote it")
    if sorted(inputs) != ["elixir", "os", "otp", "scope", "tmate", "tmux-ref"]:
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
    ("the session is not pinned to a commit", lambda s, r: (s.replace(
        "action-tmate@35b54afac29c97fb54faba5b513f8fbd1882f113 # v3.24", "action-tmate@v3"), r),
     "pinned to a full commit SHA"),
    ("the session is open to every collaborator", lambda s, r: (s.replace(
        "limit-access-to-actor: true", "limit-access-to-actor: false"), r), "limited to the actor"),
    ("the session has no time limit of its own", lambda s, r: (s.replace(
        "        timeout-minutes: 30\n", ""), r), "its own time limit"),
    ("the session runs on every event", lambda s, r: (s.replace(
        "github.event_name == 'workflow_dispatch' && matrix.tmate == 'before-tests'", "matrix.tmate == 'before-tests'"), r),
     "only on a dispatch"),
    ("the session runs on every cell", lambda s, r: (s.replace(
        " && matrix.tmate == 'on-failure'", ""), r), "only on a dispatch"),
    ("a session returns to the release", lambda s, r: (s, r + "      - uses: mxschmitt/action-tmate@35b54afac29c97fb54faba5b513f8fbd1882f113 # v3.24\n"),
     "a release never opens a debugging session"),
    ("the session moves out of the native job", lambda s, r: (s.replace(
        "      - name: Require every core and native cell\n", "      - uses: mxschmitt/action-tmate@35b54afac29c97fb54faba5b513f8fbd1882f113 # v3.24\n        timeout-minutes: 5\n        with:\n          limit-access-to-actor: true\n      - name: Require every core and native cell\n"), r),
     "belongs only in the native job"),
    ("one session is dropped", lambda s, r: (s[:s.index("      - name: Open a tmate session after a failure")] + s[s.index("\n  required-linux:"):], r),
     "before the tests and one after a failure"),
    ("the job timeout ignores the session", lambda s, r: (s.replace(
        "${{ matrix.tmate == 'off' && 5 || 60 }}", "5"), r), "cap its time"),
    ("the tmate input offers another mode", lambda s, r: (s.replace(
        "options: ['off', before-tests, on-failure]", "options: ['off', always]"), r), "plan's modes"),
    ("the tmate options leave off bare", lambda s, r: (s.replace(
        "options: ['off', before-tests, on-failure]", "options: [off, before-tests, on-failure]"), r),
     "bare off as its option"),
    ("the tmate default leaves off bare", lambda s, r: (s.replace("default: 'off'", "default: off"), r),
     "bare off as its default"),
    ("another boolean is bare in any case", lambda s, r: (s.replace("default: 'off'", "default: No"), r),
     "bare No as its default"),
    ("a choice leaves an upper case ON bare", lambda s, r: (s.replace(
        "options: [edges, full, custom]", "options: [edges, full, custom, ON]"), r), "bare ON as its option"),
    ("the tmate options are a block list with a bare off", lambda s, r: (s.replace(
        "        options: ['off', before-tests, on-failure]\n",
        "        options:\n          - off\n          - before-tests\n          - on-failure\n"), r),
     "bare off as its option"),
    ("the tmate input defaults to a session", lambda s, r: (s.replace(
        "default: 'off'", "default: before-tests"), r), "default to off"),
    ("the plan stops hearing the tmate input", lambda s, r: (s.replace(
        "          TMATE: ${{ inputs.tmate }}\n", ""), r), "plan: must pass the tmate input"),
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

    def test_the_workflow_as_written_has_no_bare_boolean(self):
        self.assertEqual(dispatch_booleans(SCAFFOLD), [])

    def test_a_quoted_block_list_has_no_bare_boolean(self):
        block = SCAFFOLD.replace("        options: ['off', before-tests, on-failure]\n",
                                 "        options:\n          - 'off'\n          - \"before-tests\"\n          - on-failure\n")
        self.assertNotEqual(block, SCAFFOLD)
        self.assertEqual(dispatch_booleans(block), [])

    def test_the_debugging_session_is_safe(self):
        self.assertEqual(session_problems(SCAFFOLD, RELEASE), [])

    def test_no_other_workflow_opens_a_session(self):
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            if path.name != "scaffold.yml":
                self.assertNotIn(TMATE, path.read_text(), path.name)

    def test_a_mutation_is_reported(self):
        for description, mutate, message in MUTATIONS:
            with self.subTest(description):
                changed = mutate(SCAFFOLD, RELEASE)
                reported = [*problems(*changed), *session_problems(*changed)]
                self.assertTrue([each for each in reported if message in each], (message, reported))

    def test_the_cell_names_follow_the_plan(self):
        self.assertEqual(field(split_jobs(SCAFFOLD)["native"], "name"), "${{ matrix.name }}")
        names = {each["name"] for each in ci_plan.plan(MANIFEST, event="push")["matrix"]["include"]}
        self.assertEqual(names, {f"Native tmux {ci_plan.edge_versions([e['tmux'] for e in MANIFEST['required_linux']])[0]} / reference",
                                 f"Native tmux {MANIFEST['required_linux'][-1]['tmux']} / reference",
                                 f"Native tmux {MANIFEST['required_linux'][-1]['tmux']} / tracking"})
        self.assertEqual(field(split_jobs(SCAFFOLD)["scaffold"], "name"), ci_plan.CORE_JOB)
        self.assertEqual(field(split_jobs(SCAFFOLD)["required-linux"], "name"), ci_plan.REQUIRED_JOB)


RAW_WORKFLOW = """name: Example
on: push
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - name: Install prerequisites
        run: |
          sudo apt-get update
          sudo apt-get install --yes jq
"""

WRAPPED_WORKFLOW = """name: Example
on: push
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - name: Install prerequisites
        run: |
          # sudo apt-get update stalls without the wrapper
          ./scripts/apt-get.sh update
          echo "apt-get is wrapped"
      - run: sudo ./scripts/apt-get.sh install --yes jq
"""

RAW_ACTION = """name: Setup
runs:
  using: composite
  steps:
    - run: sudo apt install --yes jq
      shell: bash
"""


def raw_apt_message(path, where, line, command="apt-get"):
    return f"{path}: {where}: `{line}` calls {command} directly; run it through scripts/apt-get.sh"


class AptGoesThroughTheWrapper(unittest.TestCase):
    def test_the_workflows_call_apt_only_through_the_wrapper(self):
        self.assertEqual(apt_problems(ci_sources()), [])

    def test_the_scan_reads_the_real_wrapper_step(self):
        scripts = [script for _, _, script in run_scripts(SCAFFOLD)]
        self.assertTrue([each for each in scripts if "./scripts/apt-get.sh update" in each])
        self.assertIn(".github/workflows/scaffold.yml", ci_sources())

    def test_a_raw_apt_get_is_reported_with_its_fix(self):
        path = ".github/workflows/example.yml"
        where = 'job build, step "Install prerequisites"'
        self.assertEqual(apt_problems({path: RAW_WORKFLOW}), [
            raw_apt_message(path, where, "sudo apt-get update"),
            raw_apt_message(path, where, "sudo apt-get install --yes jq"),
        ])

    def test_a_raw_apt_in_a_composite_action_is_reported(self):
        path = ".github/actions/setup/action.yml"
        self.assertEqual(apt_problems({path: RAW_ACTION}), [
            raw_apt_message(path, "the step at line 5", "sudo apt install --yes jq", "apt")])

    def test_every_spelling_of_a_raw_call_is_reported(self):
        for command in ("apt-get update", "sudo -E apt-get update", "sudo timeout --kill-after=10 180 apt-get update",
                        "if ! sudo apt-get update; then exit 1; fi", "time sudo DEBIAN_FRONTEND=noninteractive apt install jq"):
            with self.subTest(command):
                text = f"jobs:\n  build:\n    steps:\n      - name: Install\n        run: {command}\n"
                reported = apt_problems({"w.yml": text})
                self.assertEqual(len(reported), 1, reported)
                self.assertIn("run it through scripts/apt-get.sh", reported[0])

    def test_the_wrapper_a_comment_and_other_text_pass(self):
        self.assertEqual(apt_problems({".github/workflows/example.yml": WRAPPED_WORKFLOW}), [])

    def test_a_raw_call_in_the_real_workflow_is_reported(self):
        raw = replaced(SCAFFOLD, "./scripts/apt-get.sh update", "sudo apt-get update")
        self.assertEqual(apt_problems({".github/workflows/scaffold.yml": raw}), [
            raw_apt_message(".github/workflows/scaffold.yml", 'job native, step "Install tmux build prerequisites"',
                            "sudo apt-get update")])


if __name__ == "__main__":
    unittest.main()
