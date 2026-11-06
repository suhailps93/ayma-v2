import pytest
from tools.deploy_notes import parse_deploy_entries

def test_entry_split():
    content = """
## 2023-10-01 - abc123 to def456
- Fixed bug X
- Added feature Y

## 2023-09-30 - ghi789 to jkl012
- Improved performance Z
"""
    entries = parse_deploy_entries(content)
    assert len(entries) == 2
    assert entries[0][0].strftime('%Y-%m-%d') == '2023-10-01'
    assert entries[0][1] == 'abc123 to def456'
    assert entries[0][2] == ['Fixed bug X', 'Added feature Y']
    assert entries[1][0].strftime('%Y-%m-%d') == '2023-09-30'
    assert entries[1][1] == 'ghi789 to jkl012'
    assert entries[1][2] == ['Improved performance Z']

def test_bullets():
    content = """
## 2023-10-01 - abc123 to def456
- Fixed bug X
- Added feature Y

## 2023-09-30 - ghi789 to jkl012
- Improved performance Z
"""
    entries = parse_deploy_entries(content)
    assert entries[0][2] == ['Fixed bug X', 'Added feature Y']
    assert entries[1][2] == ['Improved performance Z']

def test_newest_first_order():
    content = """
## 2023-10-01 - abc123 to def456
- Fixed bug X

## 2023-09-30 - ghi789 to jkl012
- Improved performance Z
"""
    entries = parse_deploy_entries(content)
    assert entries[0][0].strftime('%Y-%m-%d') == '2023-10-01'
    assert entries[1][0].strftime('%Y-%m-%d') == '2023-09-30'

def test_missing_file_error():
    with pytest.raises(FileNotFoundError):
        parse_deploy_entries('nonexistent_path.md')
