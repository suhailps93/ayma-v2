import session_mode as sm

_FULL = {
    "name": "A",
    "birthdate": "2000-01-01",
    "gender": "Woman",
    "interested_in": ["Men"],
    "location": "Lisbon",
    "photos": [{"storage_path": "uploads/u/x.jpg"}],
}


def test_profile_complete():
    assert sm.profile_complete(_FULL) is True
    assert sm.profile_complete(None) is False
    assert sm.profile_complete({**_FULL, "location": ""}) is False
    assert sm.profile_complete({**_FULL, "interested_in": []}) is False
    assert sm.profile_complete({**_FULL, "photos": []}) is False


def test_derive_active_when_profile_complete():
    assert (
        sm.derive(is_anonymous=True, profile=_FULL, onboarding_started=False)
        == "active"
    )


def test_derive_marketing_for_a_fresh_anonymous_session():
    assert (
        sm.derive(is_anonymous=True, profile=None, onboarding_started=False)
        == "marketing"
    )


def test_derive_interview_paths():
    # linked credential, no profile yet
    assert (
        sm.derive(is_anonymous=False, profile=None, onboarding_started=False)
        == "interview"
    )
    # anonymous but tapped "get started"
    assert (
        sm.derive(is_anonymous=True, profile=None, onboarding_started=True)
        == "interview"
    )
    # anonymous, partial profile
    assert (
        sm.derive(
            is_anonymous=True, profile={"name": "A"}, onboarding_started=False
        )
        == "interview"
    )


class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data or {})


class _Ref:
    def __init__(self, user_data, profile_data):
        self._user = user_data
        self._profile = profile_data

    def get(self):
        return _Snap(self._user)

    def collection(self, _name):
        return self

    def document(self, _name):
        return _ProfileRef(self._profile)


class _ProfileRef:
    def __init__(self, data):
        self._data = data

    def get(self):
        return _Snap(self._data)


class _Db:
    def __init__(self, user_data=None, profile_data=None):
        self._ref = _Ref(user_data, profile_data)

    def collection(self, _name):
        return self

    def document(self, _name):
        return self._ref


def test_derive_for_reads_both_inputs():
    assert sm.derive_for(_Db(), "u1", True) == "marketing"
    assert (
        sm.derive_for(_Db(user_data={"onboarding_started": True}), "u1", True)
        == "interview"
    )
    assert sm.derive_for(_Db(profile_data=_FULL), "u1", False) == "active"


def test_describe_progress_empty_when_nothing_captured():
    assert sm.describe_progress(None) == ""
    assert sm.describe_progress({}) == ""


def test_describe_progress_lists_have_and_need():
    out = sm.describe_progress(
        {"name": "Dillu", "location": "San Jose", "birthdate": "1996-06-16"}
    )
    # already-captured fields are named and marked do-not-ask
    assert "do NOT ask for them again" in out
    assert "name" in out and "date of birth" in out and "where they live" in out
    # the still-missing ones are called out for collection
    assert "Still to collect" in out
    assert "gender" in out
    assert "who they're interested in" in out
    assert "at least one photo" in out


def test_describe_progress_all_captured_says_move_on():
    out = sm.describe_progress(_FULL)
    assert "Nothing else is needed" in out
    assert "Still to collect" not in out
