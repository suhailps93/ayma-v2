"""Shared in-memory Firestore fake for tests that need real collection /
subcollection / query semantics: ``account_ops``, ``account_purge``,
``knowledge_wipe``, ``admin_lookup``, and anything touching
``instagram_identities``.

Documents are keyed by a tuple path, e.g. ``("users", uid, "profile",
"main")``. Supports the small slice of the real Firestore client API these
modules actually use: ``get``/``set``/``update``/``delete``,
``collection()``/``document()`` chaining to any depth, ``stream()``,
``where()``/``limit()`` for the two query shapes this codebase issues
(``"=="`` and ``"array_contains"``), ``order_by("__name__")`` +
``start_after(snap)`` for id-paginated scans, and ``get_all(refs)`` for
batched reads.

``SERVER_TIMESTAMP`` / ``DELETE_FIELD`` are fixed sentinel objects — tests
monkeypatch each production module's imported ``firestore.SERVER_TIMESTAMP``
/ ``firestore.DELETE_FIELD`` to these same objects so identity comparisons
inside this fake's ``update()`` work without caring which module imported
them.

``db.transaction()`` returns a :class:`FakeTransaction` with optimistic
concurrency (reads record the document version; ``commit`` applies the
staged writes only if no read document changed) so production code that
relies on Firestore transactions — e.g. ``practice_core.append_turns`` —
can be exercised headlessly, including its contention retries.
"""

from __future__ import annotations

import contextlib
import threading

SERVER_TIMESTAMP = object()
DELETE_FIELD = object()


try:
    from google.api_core.exceptions import Aborted as _GoogleAborted
except ImportError:
    _GoogleAborted = Exception


class Aborted(_GoogleAborted):
    """Named like ``google.api_core.exceptions.Aborted`` so contention
    handling that classifies by exception name sees it, and inheriting
    from it so ``firestore.transactional`` retry loops catch it."""


class FakeTransaction:
    """Minimal optimistic-concurrency transaction over a :class:`FakeDb`.

    Mirrors the slice of the real Firestore ``Transaction`` API this
    codebase uses (``ref.get(transaction=txn)``, ``txn.update`` /
    ``txn.set``, ``txn.commit``): reads record the document version, and
    ``commit`` applies the staged writes only if no read document
    changed since it was read — otherwise it raises :class:`Aborted`
    and applies nothing, so the caller can retry on a fresh read.

    Faithful to google-cloud-firestore 2.x: a transaction handed out by
    ``db.transaction()`` is NOT in progress until begun via
    ``firestore.transactional`` (which calls ``_clean_up``, ``_begin``,
    ``_commit`` / ``_rollback``). Any read or write through an un-begun
    transaction raises ``ValueError: Transaction not in progress, cannot be
    used in API requests.``
    """

    def __init__(self, db, max_attempts: int = 5, read_only: bool = False):
        self._db = db
        self._reads: dict = {}
        self._writes: list = []
        self.in_progress = False
        self._id = None
        self._read_only = read_only
        self._max_attempts = max_attempts

    # -- surface used by firestore.transactional ----------------------
    def _clean_up(self):
        self._writes = []
        self._reads = {}
        self.in_progress = False
        self._id = None

    def _begin(self, retry_id=None):
        self._id = ("fake-txn", id(self), retry_id)
        self.in_progress = True

    def _commit(self):
        self.commit()

    def _rollback(self):
        self._writes = []
        self._reads = {}
        self.in_progress = False

    def _require_in_progress(self):
        if not self.in_progress:
            raise ValueError(
                "Transaction not in progress, cannot be used in API requests."
            )

    @property
    def id(self):
        if not self.in_progress:
            raise ValueError(
                "Transaction not in progress, cannot be used in API requests."
            )
        return self._id

    def get(self, ref):
        self._require_in_progress()
        with self._db._lock:
            self._reads[ref.key] = self._db._versions.get(ref.key, 0)
            return Snap(ref.key[-1], self._db.docs.get(ref.key), ref)

    def update(self, ref, data):
        self._require_in_progress()
        self._writes.append(("update", ref.key, dict(data)))

    def set(self, ref, data, merge=False):
        self._require_in_progress()
        self._writes.append(("set", ref.key, dict(data), merge))

    def delete(self, ref):
        self._require_in_progress()
        self._writes.append(("delete", ref.key, None, False))

    def commit(self):
        self._require_in_progress()
        self.in_progress = False
        with self._db._lock:
            for key, version in self._reads.items():
                if self._db._versions.get(key, 0) != version:
                    raise Aborted(f"fake transaction conflict on {key}")
            for write in self._writes:
                ref = DocRef(self._db, write[1])
                if write[0] == "update":
                    ref.update(write[2])
                elif write[0] == "set":
                    ref.set(write[2], merge=write[3])
                elif write[0] == "delete":
                    ref.delete()
            self._writes = []


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

    def _guard(self):
        # The store is a FakeDb (RLock); anything else degrades to no
        # locking rather than breaking.
        return getattr(self._store, "_lock", None) or contextlib.nullcontext()

    def _bump_version(self):
        versions = getattr(self._store, "_versions", None)
        if versions is not None:
            versions[self.key] = versions.get(self.key, 0) + 1

    def get(self, transaction=None):
        if transaction is not None:
            if not getattr(transaction, "in_progress", False):
                raise ValueError(
                    "Transaction not in progress, cannot be used in API requests."
                )
            return transaction.get(self)
        return Snap(self.key[-1], self._store.docs.get(self.key), self)

    def set(self, data, merge=False):
        with self._guard():
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
            self._bump_version()

    def update(self, data):
        with self._guard():
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
            self._bump_version()

    def delete(self):
        with self._guard():
            self._store.docs.pop(self.key, None)
            self._bump_version()

    def collection(self, name):
        return CollRef(self._store, self.key + (name,))


class Query:
    def __init__(self, coll, filters=None, limit_n=None, order_field=None,
                 start_after_id=None, order_desc=False):
        self._coll = coll
        self._filters = filters or []
        self._limit = limit_n
        self._order = order_field
        self._start_after_id = start_after_id
        self._order_desc = order_desc

    def where(self, field, op, value):
        return Query(self._coll, self._filters + [(field, op, value)],
                     self._limit, self._order, self._start_after_id,
                     self._order_desc)

    def limit(self, n):
        return Query(self._coll, self._filters, n, self._order,
                     self._start_after_id, self._order_desc)

    def order_by(self, field, direction=None):
        desc = str(direction).upper().startswith("DESC")
        return Query(self._coll, self._filters, self._limit, field,
                     self._start_after_id, desc)

    def start_after(self, snap):
        return Query(self._coll, self._filters, self._limit, self._order,
                     snap.id, self._order_desc)

    def stream(self):
        depth = len(self._coll.key)
        out = []
        for key, data in list(self._coll._store.docs.items()):
            if len(key) != depth + 1 or key[:depth] != self._coll.key:
                continue
            if self._matches(data):
                out.append(StreamSnap(self._coll._store, key, data))
        if self._order == "__name__":
            out.sort(key=lambda s: s.id)
        elif self._order is not None:
            # Field ordering (e.g. chat_history's created_at): datetimes sort
            # by value; anything else (notably the SERVER_TIMESTAMP sentinel
            # append() writes) sorts as "no timestamp" so equal-keyed rows
            # keep insertion order instead of raising on a comparison.
            def _key(snap):
                v = (snap.to_dict() or {}).get(self._order)
                return (1, v.isoformat()) if hasattr(v, "isoformat") else (0, "")

            out.sort(key=_key, reverse=self._order_desc)
        if self._start_after_id is not None:
            out = [s for s in out if s.id > self._start_after_id]
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

    def order_by(self, field, **kw):
        return Query(self).order_by(field, **kw)


class FakeDb:
    def __init__(self, seed: dict | None = None):
        # seed: {tuple_path: dict_data}
        self.docs: dict[tuple, dict] = dict(seed or {})
        # Per-document write versions for FakeTransaction conflict
        # detection; bumped by every direct set/update/delete.
        self._versions: dict[tuple, int] = {}
        # Guards check-then-apply sequences (transaction commit, and
        # concurrent direct writes) so the fake is safe to use from
        # threads; an RLock so commit can reuse DocRef.set/update.
        self._lock = threading.RLock()

    def collection(self, name):
        return CollRef(self, (name,))

    def get_all(self, refs):
        return [r.get() for r in refs]

    def transaction(self, max_attempts: int = 5, read_only: bool = False):
        """Return a new optimistic-concurrency transaction (see
        :class:`FakeTransaction`)."""
        return FakeTransaction(self, max_attempts=max_attempts, read_only=read_only)
