import schema


class _Ref:
    def __init__(self, path):
        self.path = path

    def collection(self, name):
        return _Ref(self.path + [name])

    def document(self, doc_id):
        return _Ref(self.path + [doc_id])


class _Db:
    def collection(self, name):
        return _Ref([name])


def test_helpers_build_the_right_paths():
    db = _Db()
    assert schema.user_doc(db, "u1").path == ["users", "u1"]
    assert schema.profile_doc(db, "u1").path == [
        "users", "u1", "profile", "main"
    ]
    assert schema.user_subcollection(db, "u1", schema.WIKI_PAGES).path == [
        "users", "u1", "wiki_pages"
    ]


def test_reexports_match_the_domain_modules():
    import dm_schema
    import matching_schema
    import notifications_schema
    import pair_key

    assert schema.MATCHES_COLLECTION == matching_schema.MATCHES_COLLECTION
    assert schema.DM_THREADS_COLLECTION == dm_schema.DM_THREADS_COLLECTION
    assert schema.NOTIFICATIONS_COLLECTION == \
        notifications_schema.NOTIFICATIONS_COLLECTION
    assert schema.sorted_pair_key is pair_key.sorted_pair_key
    assert schema.sorted_pair_key("b", "a") == "a__b"


def test_collection_name_constants_are_stable():
    # These strings are the on-disk contract — guard against accidental renames.
    assert (schema.USERS, schema.PROFILE, schema.PROFILE_DOC) == (
        "users", "profile", "main"
    )
    assert schema.WIKI_PAGES == "wiki_pages"
    assert schema.RAW_TURNS == "raw_turns"
    assert schema.USER_MEDIA == "user_media"
    assert schema.PF_PAUSED == "paused"
    assert schema.PF_AYMA_VOICE == "ayma_voice_name"
