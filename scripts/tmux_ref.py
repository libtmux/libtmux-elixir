"""Resolve a tmux ref to a commit of github.com/tmux/tmux.

Usage: python3 scripts/tmux_ref.py REF

REF is a tag, a branch or a full 40-hex commit. The commit is printed alone, so
a workflow can build it and name the build for the commit, never for the ref.
"""
import re
import subprocess
import sys

REPOSITORY = "https://github.com/tmux/tmux.git"
REF_PATTERN = re.compile(r"[A-Za-z0-9._/-]{1,64}")
FULL_COMMIT = re.compile(r"[0-9a-f]{40}")
SHORT_COMMIT = re.compile(r"[0-9a-f]{7,39}")


def check_ref(ref):
    """Refuse a ref that is malformed or could be read as a git option."""
    if not REF_PATTERN.fullmatch(ref):
        raise ValueError(f"tmux ref {ref!r} must match {REF_PATTERN.pattern}")
    if ref.startswith("-") or ".." in ref or ref.endswith(("/", ".lock")):
        raise ValueError(f"tmux ref {ref!r} is not a usable git ref")
    if SHORT_COMMIT.fullmatch(ref):
        raise ValueError(f"tmux ref {ref!r} looks like an abbreviated commit; give all 40 hex digits")
    return ref


def resolve_commit(ref, repository=REPOSITORY):
    """Return the commit a tag, branch or full commit names.

    A tag, peeled to its commit, wins over a branch of the same name, as it
    does for a clone.
    """
    check_ref(ref)
    if FULL_COMMIT.fullmatch(ref):
        return ref
    names = (f"refs/tags/{ref}^{{}}", f"refs/tags/{ref}", f"refs/heads/{ref}")
    listing = subprocess.run(["git", "ls-remote", "--", repository, *names],
                             check=True, capture_output=True, text=True).stdout
    found = {}
    for line in listing.splitlines():
        commit, _, name = line.partition("\t")
        found[name] = commit
    for name in names:
        if FULL_COMMIT.fullmatch(found.get(name, "")):
            return found[name]
    raise ValueError(f"{ref} is not a tag, a branch or a full commit of {repository}")


def main(argv):
    if len(argv) != 1:
        print("usage: python3 scripts/tmux_ref.py REF", file=sys.stderr)
        return 2
    try:
        print(resolve_commit(argv[0]))
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"tmux_ref: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
