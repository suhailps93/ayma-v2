"""Shared in-memory Firestore fake for tests that need real collection /
subcollection / query semantics: ``account_ops``, ``account_purge``,
``knowledge_wipe``, ``admin_lookup``, and anything touching
``instagram_identities``.

Documents are keyed by a tuple path, e.g. ``("users", uid, "profile",
"main")``. Supports the small slice of the real Firestore client API these
modules actually use: ``get``/``set``/``update``/``delete``,
``collection()``/``document()`` chaining to any depth, ``stream()``, and
``where()``/``limit()`` for the two query shapes this codebase issues
(``"=="`` and ``"array_contains"``).

``SERVER_TIMESTAMP`` / ``DELETE_FIELD`` are fixed sentinel objects — tests
monkeypatch each production module's imported ``firestore.SERVER_TIMESTAMP``
/ ``firestore.DELETE_FIELD`` to these same objects so identity comparisons
inside this fake's ``update()`` work without caring which module imported
them.
"""

from __future__ import annotations

SERVER_TIMESTAMP = object()
DELETE_FIELD = object()


class Snap:
    def __init__(self, doc_id, data, ref):
        self.id = doc_id
        self._data = data
        self._ref = ref

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)

    @property
    def reference(self):
        return self._ref


class StreamSnap:
    def __init__(self, store, key, data):
        self._store = store
        self._key = key
        self.id = key[-1]
        self._data = data

    def to_dict(self):
        return dict(self._data)

    @property
    def reference(self):
        return DocRef(self._store, self._key)


class DocRef:
    def __init__(self, store, key):
        self._store = store
        self.key = key

    @property
    def id(self):
        return self.key[-1]

    def get(self):
        return Snap(self.key[-1], self._store.docs.get(self.key), self)

    def set(self, data, merge=False):
        cur = self._store.docs.get(self.key) if merge else None
        cur = dict(cur) if cur else {}
        for k, v in data.items():
            if v is DELETE_FIELD:
                cur.pop(k, None)
            elif v is SERVER_TIMESTAMP:
                cur[k] = SERVER_TIMESTAMP
            else:
                cur[k] = v
        self._store.docs[self.key] = cur

    def update(self, data):
        if self.key not in self._store.docs:
            raise LookupError(f"no such document: {self.key}")
        cur = dict(self._store.docs[self.key])
        for k, v in data.items():
            if v is DELETE_FIELD:
                cur.pop(k, None)
            elif v is SERVER_TIMESTAMP:
                cur[k] = SERVER_TIMESTAMP
            else:
                cur[k] = v
        self._store.docs[self.key] = cur

    def delete(self):
        self._store.docs.pop(self.key, None)

    def collection(self, name):
        return CollRef(self._store, self.key + (name,))


class Query:
    def __init__(self, coll, filters=None, limit_n=None):
        self._coll = coll
        self._filters = filters or []
        self._limit = limit_n

    def where(self, field, op, value):
        return Query(self._coll, self._filters + [(field, op, value)], self._limit)

    def limit(self, n):
        return Query(self._coll, self._filters, n)

    def stream(self):
        depth = len(self._coll.key)
        out = []
        for key, data in list(self._coll._store.docs.items()):
            if len(key) != depth + 1 or key[:depth] != self._coll.key:
                continue
            if self._matches(data):
                out.append(StreamSnap(self._coll._store, key, data))
        if self._limit is not None:
            out = out[: self._limit]
        return iter(out)

    def _matches(self, data) -> bool:
        for field, op, value in self._filters:
            fv = data.get(field)
            if op == "==":
                if fv != value:
                    return False
            elif op == "array_contains":
                if not (isinstance(fv, list) and value in fv):
                    return False
            else:  # pragma: no cover - only the two ops above are used
                raise NotImplementedError(op)
        return True


class CollRef:
    def __init__(self, store, key):
        self._store = store
        self.key = key

    def document(self, doc_id=None):
        if doc_id is None:
            doc_id = f"auto{len(self._store.docs)}_{id(object())}"
        return DocRef(self._store, self.key + (doc_id,))

    def add(self, data):
        ref = self.document()
        ref.set(data)
        return ref

    def stream(self):
        return Query(self).stream()

    def where(self, field, op, value):
        return Query(self).where(field, op, value)

    def limit(self, n):
        return Query(self).limit(n)


class FakeDb:
    def __init__(self, seed: dict | None = None):
        # seed: {tuple_path: dict_data}
        self.docs: dict[tuple, dict] = dict(seed or {})

    def collection(self, name):
        return CollRef(self, (name,))
