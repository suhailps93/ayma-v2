import subprocess
import sys
import io
from contextlib import redirect_stdout
import pytest

# Import the module under test directly to avoid subprocess + CLI-arg issues.
sys.path.insert(0, str(__import__('pathlib').Path(__file__).parent))
from branch_audit import audit_branches


def _run(clones_dir: str, shared_repo: str):
    """Call audit_branches(), capture stdout, and catch SystemExit for the exit code."""
    buf = io.StringIO()
    try:
        with redirect_stdout(buf):
            audit_branches(clones_dir, shared_repo)
        exit_code = 0
    except SystemExit as exc:
        exit_code = int(exc.code)
    return buf.getvalue().strip(), exit_code


def _init_repo(path):
    subprocess.run(['git', 'init', str(path)], capture_output=True, check=True)
    subprocess.run(['git', '-C', str(path), 'config', 'user.email', 'test@test.com'],
                   capture_output=True, check=True)
    subprocess.run(['git', '-C', str(path), 'config', 'user.name', 'Test'],
                   capture_output=True, check=True)


def _checkout_branch(path, branch):
    # `git checkout -b` on an empty repo only sets HEAD; the branch ref is not
    # created until a commit exists. Make an empty initial commit so that
    # `git branch --list` actually reports the branch name.
    subprocess.run(['git', '-C', str(path), 'checkout', '-b', branch],
                   capture_output=True, check=True)
    subprocess.run(
        ['git', '-C', str(path), 'commit', '--allow-empty', '-m', f'init {branch}'],
        capture_output=True, check=True,
    )


def test_all_ok(tmp_path):
    shared = tmp_path / 'shared'
    clone1 = tmp_path / 'clones' / 'fleet' / 'clone1'
    shared.mkdir()
    clone1.mkdir(parents=True)

    _init_repo(shared)
    _init_repo(clone1)
    _checkout_branch(shared, 'branch1')
    _checkout_branch(clone1, 'branch1')

    output, exit_code = _run(str(tmp_path / 'clones'), str(shared))
    assert output == "branch1, yes, yes, OK"
    assert exit_code == 0


def test_unpushed_branch(tmp_path):
    shared = tmp_path / 'shared'
    clone1 = tmp_path / 'clones' / 'fleet' / 'clone1'
    shared.mkdir()
    clone1.mkdir(parents=True)

    _init_repo(shared)
    _init_repo(clone1)
    _checkout_branch(clone1, 'branch2')

    output, exit_code = _run(str(tmp_path / 'clones'), str(shared))
    assert "branch2, yes, no, UNPUSHED" in output
    assert exit_code == 1


def test_orphaned_branch(tmp_path):
    shared = tmp_path / 'shared'
    clone1 = tmp_path / 'clones' / 'fleet' / 'clone1'
    shared.mkdir()
    clone1.mkdir(parents=True)

    _init_repo(shared)
    _init_repo(clone1)
    _checkout_branch(shared, 'branch3')

    output, exit_code = _run(str(tmp_path / 'clones'), str(shared))
    assert "branch3, no, yes, ORPHANED" in output
    assert exit_code == 1


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
