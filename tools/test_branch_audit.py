import pytest
import subprocess
import tempfile

def run_branch_audit(clones_dir: str, shared_repo: str) -> str:
    result = subprocess.run(['python', 'tools/branch_audit.py', '--clones-dir', clones_dir, '--shared-repo', shared_repo], capture_output=True, text=True)
    return result.stdout.strip(), result.returncode

def test_all_ok(tmp_path):
    (tmp_path / 'shared').mkdir()
    (tmp_path / 'clones' / 'fleet/clone1').mkdir(parents=True)
    subprocess.run(['git', '-C', tmp_path / 'shared', 'init'])
    subprocess.run(['git', '-C', tmp_path / 'clones' / 'fleet/clone1', 'init'])
    subprocess.run(['git', '-C', tmp_path / 'shared', 'checkout', '-b', 'branch1'])
    subprocess.run(['git', '-C', tmp_path / 'clones' / 'fleet/clone1', 'checkout', '-b', 'branch1'])

    output, exit_code = run_branch_audit(str(tmp_path / 'clones'), str(tmp_path / 'shared'))
    assert output == "branch1, yes, yes, OK"
    assert exit_code == 0

def test_unpushed_branch(tmp_path):
    (tmp_path / 'shared').mkdir()
    (tmp_path / 'clones' / 'fleet/clone1').mkdir(parents=True)
    subprocess.run(['git', '-C', tmp_path / 'shared', 'init'])
    subprocess.run(['git', '-C', tmp_path / 'clones' / 'fleet/clone1', 'init'])
    subprocess.run(['git', '-C', tmp_path / 'clones' / 'fleet/clone1', 'checkout', '-b', 'branch2'])

    output, exit_code = run_branch_audit(str(tmp_path / 'clones'), str(tmp_path / 'shared'))
    assert "branch2, yes, no, UNPUSHED" in output
    assert exit_code == 1

def test_orphaned_branch(tmp_path):
    (tmp_path / 'shared').mkdir()
    (tmp_path / 'clones' / 'fleet/clone1').mkdir(parents=True)
    subprocess.run(['git', '-C', tmp_path / 'shared', 'init'])
    subprocess.run(['git', '-C', tmp_path / 'clones' / 'fleet/clone1', 'init'])
    subprocess.run(['git', '-C', tmp_path / 'shared', 'checkout', '-b', 'branch3'])

    output, exit_code = run_branch_audit(str(tmp_path / 'clones'), str(tmp_path / 'shared'))
    assert "branch3, no, yes, ORPHANED" in output
    assert exit_code == 1

if __name__ == '__main__':
    pytest.main()
