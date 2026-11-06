import pytest
from tools.deploy_notes import parse_deploy_entries

def test_entry_split(tmp_path):
    content = """
## 2023-10-01 - abc123 to def456
- Fixed bug X
- Added feature Y

## 2023-09-30 - ghi789 to jkl012
- Improved performance Z
"""
    test_file = tmp_path / "deploys.md"
    test_file.write_text(content)
    entries = parse_deploy_entries(str(test_file))
    assert len(entries) == 2
    assert entries[0][0].strftime('%Y-%m-%d') == '2023-10-01'
    assert entries[0][1] == 'abc123 to def456'
    assert entries[0][2] == ['Fixed bug X', 'Added feature Y']
    assert entries[1][0].strftime('%Y-%m-%d') == '2023-09-30'
    assert entries[1][1] == 'ghi789 to jkl012'
    assert entries[1][2] == ['Improved performance Z']

def test_bullets(tmp_path):
    content = """
## 2023-10-01 - abc123 to def456
- Fixed bug X
- Added feature Y

## 2023-09-30 - ghi789 to jkl012
- Improved performance Z
"""
    test_file = tmp_path / "deploys.md"
    test_file.write_text(content)
    entries = parse_deploy_entries(str(test_file))
    assert entries[0][2] == ['Fixed bug X', 'Added feature Y']
    assert entries[1][2] == ['Improved performance Z']

def test_newest_first_order(tmp_path):
    content = """
## 2023-10-01 - abc123 to def456
- Fixed bug X

## 2023-09-30 - ghi789 to jkl012
- Improved performance Z
"""
    test_file = tmp_path / "deploys.md"
    test_file.write_text(content)
    entries = parse_deploy_entries(str(test_file))
    assert entries[0][0].strftime('%Y-%m-%d') == '2023-10-01'
    assert entries[1][0].strftime('%Y-%m-%d') == '2023-09-30'

def test_missing_file_error():
    with pytest.raises(FileNotFoundError):
        parse_deploy_entries('nonexistent_path.md')
