import os
import re
from datetime import datetime

def parse_deploy_entries(file_path):
    with open(file_path, 'r') as file:
        content = file.read()

    entries = []
    entry_pattern = re.compile(r'## (\d{4}-\d{2}-\d{2}) - (\w+) to (\w+)\n(.*?)(?=\n## |\Z)', re.DOTALL)
    for match in entry_pattern.finditer(content):
        date_str, start_commit, end_commit, details = match.groups()
        date = datetime.strptime(date_str, '%Y-%m-%d')
        bullets = [line.strip('- ') for line in details.split('\n') if line.startswith('-')]
        entries.append((date, f"{start_commit} to {end_commit}", bullets))

    return sorted(entries, reverse=True)

def print_deploy_entries(file_path, n):
    entries = parse_deploy_entries(file_path)
    for date, commit_range, bullets in entries[:n]:
        print(f"Date: {date.strftime('%Y-%m-%d')}")
        print(f"Commit Range: {commit_range}")
        print("What's Different:")
        for bullet in bullets:
            print(f"- {bullet}")
        print()

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='Print the N newest deploy entries.')
    parser.add_argument('file_path', nargs='?', default='~/workspace/ayma-inbox/deploys.md')
    parser.add_argument('--n', type=int, default=5)
    args = parser.parse_args()

    file_path = os.path.expanduser(args.file_path)
    print_deploy_entries(file_path, args.n)
