import pytest

from tools.range_report import group_files

def test_group_files_empty():
    paths = []
    expected = {
        'client': [],
        'backend': [],
        'infra': []
    }
    assert group_files(paths) == expected

def test_group_files_client():
    paths = ['ayma_flutter/lib/main.dart', 'ayma_flutter/lib/screens/chat.dart', 'lib/file1.py']
    expected = {
        'client': ['ayma_flutter/lib/main.dart', 'ayma_flutter/lib/screens/chat.dart', 'lib/file1.py'],
        'backend': [],
        'infra': []
    }
    assert group_files(paths) == expected

def test_group_files_real_repo_paths():
    paths = [
        'ayma_flutter/lib/main.dart',
        'ayma_flutter/lib/screens/chat.dart',
        'functions/bootstrap/main.py',
        'functions/bootstrap/routes/profile.py',
        'scripts/build-apk.sh',
        'docs/API_INVENTORY.md',
    ]
    expected = {
        'client': ['ayma_flutter/lib/main.dart', 'ayma_flutter/lib/screens/chat.dart'],
        'backend': ['functions/bootstrap/main.py', 'functions/bootstrap/routes/profile.py'],
        'infra': ['scripts/build-apk.sh', 'docs/API_INVENTORY.md']
    }
    assert group_files(paths) == expected

def test_group_files_backend():
    paths = ['backend/file1.py', 'functions/file2.js']
    expected = {
        'client': [],
        'backend': ['backend/file1.py', 'functions/file2.js'],
        'infra': []
    }
    assert group_files(paths) == expected

def test_group_files_infra():
    paths = ['scripts/setup.sh', 'README.md']
    expected = {
        'client': [],
        'backend': [],
        'infra': ['scripts/setup.sh', 'README.md']
    }
    assert group_files(paths) == expected
