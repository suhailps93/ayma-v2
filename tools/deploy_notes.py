import os
import re
from datetime import datetime

# Real deploy-log format (~/workspace/ayma-inbox/deploys.md):
#   ### YYYY-MM-DD HH:MM PST — staging deploy <sha>..<sha>
#   ### YYYY-MM-DD HH:MM PST — BASELINE at <sha> (...)
#   ### YYYY-MM-DD HH:MM PST — phone catch-up install
#   ### YYYY-MM-DD HH:MM PST — SUPERSEDED: <sha> phone build ...
# Commit ranges use "..", never " to ".

_HEADER = re.compile(
    r"### (\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}) [A-Z]+ — (.*?)\n(.*?)(?=\n### |\Z)",
    re.DOTALL,
)
_RANGE = re.compile(r"([0-9a-f]{7,40})\.\.([0-9a-f]{7,40})")
_SHA = re.compile(r"\b([0-9a-f]{7,40})\b")
_COMMIT_LINE = re.compile(r"^- Commit: `([0-9a-f]{7,40})`", re.MULTILINE)


def _commit_range(title, details):
    match = _RANGE.search(title)
    if match:
        return f"{match.group(1)}..{match.group(2)}"
    match = _SHA.search(title)
    if match:
        return match.group(1)
    match = _COMMIT_LINE.search(details)
    if match:
        return match.group(1)
    match = _SHA.search(details)
    if match:
        return match.group(1)
    return ""


def parse_deploy_entries(file_path):
    with open(file_path, "r") as file:
        content = file.read()

    entries = []
    for match in _HEADER.finditer(content):
        date_str, time_str, title, details = match.groups()
        date = datetime.strptime(f"{date_str} {time_str}", "%Y-%m-%d %H:%M")
        bullets = [line.strip("- ") for line in details.split("\n") if line.startswith("-")]
        entries.append((date, _commit_range(title, details), bullets))

    return sorted(entries, reverse=True)


def print_deploy_entries(file_path, n):
    entries = parse_deploy_entries(file_path)
    for date, commit_range, bullets in entries[:n]:
        print(f"Date: {date.strftime('%Y-%m-%d %H:%M')}")
        print(f"Commit Range: {commit_range}")
        print("What's Different:")
        for bullet in bullets:
            print(f"- {bullet}")
        print()


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Print the N newest deploy entries.")
    parser.add_argument("file_path", nargs="?", default="~/workspace/ayma-inbox/deploys.md")
    parser.add_argument("--n", type=int, default=5)
    args = parser.parse_args()

    file_path = os.path.expanduser(args.file_path)
    print_deploy_entries(file_path, args.n)
