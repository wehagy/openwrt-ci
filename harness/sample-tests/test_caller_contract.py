"""Sample caller tests: prove, inside a real QEMU test job, what test.yml
promises to the tests of a calling repository (tests_path, test_secrets).

This repository calls its own test.yml with tests_path: harness/sample-tests
and test_secrets: SAMPLE_SECRET, so a regression is caught here and not only
in a caller. No test needs the VM; they run in the same pytest session as the
generic test and share its environment.
"""

import os
from pathlib import Path

HARNESS_FILES = {"conftest.py", "harness_util.py", "test_package.py"}
SECRETS_JSON = "HARNESS_SECRETS_JSON"
LISTED = "SAMPLE_SECRET"


def test_files_run_next_to_the_harness_files():
    """install-tests.sh copied this file next to the harness test files."""
    names = {p.name for p in Path(__file__).parent.iterdir()}
    assert HARNESS_FILES <= names
    assert Path(__file__).name in names


def test_listed_secret_is_exported():
    """A name in test_secrets is in the environment, set or empty (a secret
    that does not exist is exported empty, so a test can skip with a reason)."""
    assert LISTED in os.environ


def test_unlisted_secrets_do_not_reach_the_tests():
    """toJSON(secrets) always holds github_token; only listed names pass."""
    for name in ("GITHUB_TOKEN", "github_token", SECRETS_JSON, "HARNESS_TEST_SECRETS"):
        assert name not in os.environ, name


def _ancestor_pids():
    pid = os.getppid()
    while pid > 1:
        yield pid
        stat = Path(f"/proc/{pid}/stat").read_text()
        pid = int(stat.rsplit(")", 1)[1].split()[1])


def test_no_ancestor_keeps_the_secrets_json():
    """The step's bash exec's the wrapper: no process above pytest has the
    JSON with all the caller secrets in its environment (a descendant could
    read /proc/<ppid>/environ)."""
    checked = 0
    for pid in _ancestor_pids():
        try:
            environ = Path(f"/proc/{pid}/environ").read_bytes()
        except PermissionError:
            break
        entries = environ.split(b"\0")
        assert not any(
            entry.startswith(SECRETS_JSON.encode() + b"=") for entry in entries
        ), f"pid {pid} keeps {SECRETS_JSON}"
        checked += 1
    assert checked >= 2, "fewer than two ancestors could be read"
