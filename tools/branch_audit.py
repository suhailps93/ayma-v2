import os
import subprocess
from typing import List


def get_branches(repo_path: str) -> List[str]:
    result = subprocess.run(
        ['git', '-C', repo_path, 'branch', '--list'],
        capture_output=True,
        text=True,
    )
    return [line.strip().replace('* ', '') for line in result.stdout.splitlines() if line.strip()]


def audit_branches(clones_dir: str = '~/workspace/ayma-fleet-clones', shared_repo: str = '~/workspace/ayma') -> None:
    clones_dir = os.path.expanduser(clones_dir)
    shared_repo = os.path.expanduser(shared_repo)

    shared_branches = set(get_branches(shared_repo))
    clone_branches = {}

    # os.listdir returns one level of names, so "fleet/clone1" directories appear
    # as a "fleet" entry containing "clone1". Walk two levels to find repos whose
    # top-level parent dir is named "fleet".
    for top in os.listdir(clones_dir):
        if top != 'fleet':
            continue
        fleet_dir = os.path.join(clones_dir, top)
        if not os.path.isdir(fleet_dir):
            continue
        for name in os.listdir(fleet_dir):
            clone_path = os.path.join(fleet_dir, name)
            if os.path.isdir(clone_path):
                key = f'fleet/{name}'
                clone_branches[key] = set(get_branches(clone_path))

    all_branches = shared_branches.union(*clone_branches.values()) if clone_branches else shared_branches

    rows = []
    for branch in sorted(all_branches):
        present_in_clones = 'yes' if any(branch in branches for branches in clone_branches.values()) else 'no'
        present_in_shared = 'yes' if branch in shared_branches else 'no'

        if present_in_clones == 'no':
            status = 'ORPHANED'
        elif present_in_shared == 'no':
            status = 'UNPUSHED'
        else:
            status = 'OK'

        print(f"{branch}, {present_in_clones}, {present_in_shared}, {status}")
        rows.append(status)

    if any(s in ('UNPUSHED', 'ORPHANED') for s in rows):
        exit(1)
    else:
        exit(0)


if __name__ == '__main__':
    audit_branches()
