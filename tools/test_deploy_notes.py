import os

import pytest

from tools.deploy_notes import parse_deploy_entries

REAL_FORMAT = """
### 2023-10-01 09:15 PST — staging deploy abc1234..def4567
- Fixed bug X
- Added feature Y

### 2023-09-30 18:02 PST — staging deploy 9a8b7c6..5d4e3f2
- Improved performance Z
"""


def test_entry_split(tmp_path):
    test_file = tmp_path / "deploys.md"
    test_file.write_text(REAL_FORMAT)
    entries = parse_deploy_entries(str(test_file))
    assert len(entries) == 2
    assert entries[0][0].strftime("%Y-%m-%d %H:%M") == "2023-10-01 09:15"
    assert entries[0][1] == "abc1234..def4567"
    assert entries[0][2] == ["Fixed bug X", "Added feature Y"]
    assert entries[1][0].strftime("%Y-%m-%d %H:%M") == "2023-09-30 18:02"
    assert entries[1][1] == "9a8b7c6..5d4e3f2"
    assert entries[1][2] == ["Improved performance Z"]


def test_bullets(tmp_path):
    test_file = tmp_path / "deploys.md"
    test_file.write_text(REAL_FORMAT)
    entries = parse_deploy_entries(str(test_file))
    assert entries[0][2] == ["Fixed bug X", "Added feature Y"]
    assert entries[1][2] == ["Improved performance Z"]


def test_newest_first_order(tmp_path):
    content = """
### 2023-09-30 18:02 PST — staging deploy 9a8b7c6..5d4e3f2
- Improved performance Z

### 2023-10-01 09:15 PST — staging deploy abc1234..def4567
- Fixed bug X
"""
    test_file = tmp_path / "deploys.md"
    test_file.write_text(content)
    entries = parse_deploy_entries(str(test_file))
    assert entries[0][0].strftime("%Y-%m-%d %H:%M") == "2023-10-01 09:15"
    assert entries[1][0].strftime("%Y-%m-%d %H:%M") == "2023-09-30 18:02"


def test_baseline_catchup_and_superseded_entries(tmp_path):
    content = """
### 2023-10-01 11:15 PST — BASELINE at b46ce57 (staging cloud live, phone install pending)
- Commit: `b46ce57` (staging tip verified)
- Staging cloud: already live

### 2023-10-01 14:11 PST — phone catch-up install
- Commit: `e4fcadd` (staging already live)
- phone: installed to 10.0.0.203:38897 (dev apk)

### 2023-10-01 12:06 PST — SUPERSEDED: 2109665 phone build ran with the old command
- Status: SUPERSEDED \u2014 never installed
"""
    test_file = tmp_path / "deploys.md"
    test_file.write_text(content)
    entries = parse_deploy_entries(str(test_file))
    assert len(entries) == 3
    assert entries[0][1] == "e4fcadd"
    assert entries[1][1] == "2109665"
    assert entries[2][1] == "b46ce57"
    assert entries[0][0].strftime("%Y-%m-%d %H:%M") == "2023-10-01 14:11"


def test_missing_file_error():
    with pytest.raises(FileNotFoundError):
        parse_deploy_entries("nonexistent_path.md")


REAL_DEPLOYS = os.path.expanduser("~/workspace/ayma-inbox/deploys.md")


@pytest.mark.skipif(not os.path.exists(REAL_DEPLOYS), reason="real deploy log not present")
def test_real_deploy_log_parses():
    with open(REAL_DEPLOYS) as f:
        expected = sum(1 for line in f if line.startswith("### "))
    entries = parse_deploy_entries(REAL_DEPLOYS)
    assert expected > 0
    assert len(entries) == expected
    assert all(entries[i][0] >= entries[i + 1][0] for i in range(len(entries) - 1))
    assert any(".." in entry[1] for entry in entries)
