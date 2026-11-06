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
    paths = ['lib/file1.py', 'lib/file2.dart']
    expected = {
        'client': ['lib/file1.py', 'lib/file2.dart'],
        'backend': [],
        'infra': []
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
