import subprocess
import sys

def group_files(paths):
    groups = {
        'client': [],
        'backend': [],
        'infra': []
    }
    
    for path in paths:
        if path.startswith('lib/'):
            groups['client'].append(path)
        elif path.startswith('backend/') or path.startswith('functions/'):
            groups['backend'].append(path)
        else:
            groups['infra'].append(path)
    
    return groups

def main(base_ref, tip_ref):
    try:
        result = subprocess.run(['git', 'diff', '--name-only', base_ref, tip_ref], capture_output=True, text=True, check=True)
        paths = result.stdout.splitlines()
        
        groups = group_files(paths)
        
        for area, files in groups.items():
            print(f"{area}: {len(files)} files")
            for file in files:
                print(f"  {file}")
    
    except subprocess.CalledProcessError as e:
        print(f"Error running git diff: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print("Usage: python range_report.py <base_ref> <tip_ref>", file=sys.stderr)
        sys.exit(1)
    
    main(sys.argv[1], sys.argv[2])
