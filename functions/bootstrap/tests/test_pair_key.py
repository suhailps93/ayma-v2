import pytest

from pair_key import sorted_pair_key, uids_from_pair_key


def test_order_independent():
    assert sorted_pair_key("bbb", "aaa") == sorted_pair_key("aaa", "bbb")
    assert sorted_pair_key("aaa", "bbb") == "aaa__bbb"


def test_round_trips():
    key = sorted_pair_key("zeta9", "alpha1")
    assert uids_from_pair_key(key) == ("alpha1", "zeta9")


def test_rejects_bad_input():
    with pytest.raises(ValueError):
        sorted_pair_key("x", "x")
    with pytest.raises(ValueError):
        sorted_pair_key("", "y")
    with pytest.raises(ValueError):
        uids_from_pair_key("no-separator")
