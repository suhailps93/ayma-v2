import os
import subprocess
from typing import List

def get_branches(repo_path: str) -> List[str]:
    result = subprocess.run(['git', '-C', repo_path, 'branch', '--list'], capture_output=True, text=True)
    return [line.strip().replace('* ', '') for line in result.stdout.splitlines()]

def audit_branches(clones_dir: str = '~/workspace/ayma-fleet-clones', shared_repo: str = '~/workspace/ayma') -> None:
    clones_dir = os.path.expanduser(clones_dir)
    shared_repo = os.path.expanduser(shared_repo)

    shared_branches = set(get_branches(shared_repo))
    clone_branches = {}

    for clone in os.listdir(clones_dir):
        if not clone.startswith('fleet/'):
            continue
        clone_path = os.path.join(clones_dir, clone)
        if os.path.isdir(clone_path):
            branches = get_branches(clone_path)
            clone_branches[clone] = set(branches)

    all_clones = set(clone_branches.keys())
    all_shared = shared_branches

    for branch in sorted(shared_branches.union(*clone_branches.values())):
        present_in_clones = 'yes' if any(branch in branches for branches in clone_branches.values()) else 'no'
        present_in_shared = 'yes' if branch in shared_branches else 'no'

        if present_in_clones == 'no':
            status = 'ORPHANED'
        elif present_in_shared == 'no':
            status = 'UNPUSHED'
        else:
            status = 'OK'

        print(f"{branch}, {present_in_clones}, {present_in_shared}, {status}")

    if any(
        status in ['UNPUSHED', 'ORPHANED']
        for branch, present_in_clones, present_in_shared, status in zip(
            sorted(shared_branches.union(*clone_branches.values())),
            [present_in_clones] * len(shared_branches.union(*clone_branches.values())),
            [present_in_shared] * len(shared_branches.union(*clone_branches.values())),
            [status] * len(shared_branches.union(*clone_branches.values()))
        )
    ):
        exit(1)
    else:
        exit(0)

if __name__ == '__main__':
    audit_branches()
