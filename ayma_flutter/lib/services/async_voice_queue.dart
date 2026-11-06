import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'ayma_session.dart';
import 'connection_heartbeat.dart';
import 'transcript_store.dart';

/// Uploads voice clips to Storage. Separated so tests fake the backend
/// without a Firebase project.
abstract class AsyncVoiceUploader {
  /// Upload [file] to [storagePath] (`uploads/{uid}/…`) as `audio/wav`.
  Future<void> upload(String storagePath, File file);

  /// A playable download URL for an uploaded clip, or null when it cannot
  /// be resolved right now (transient failure — the local file still plays).
  Future<String?> downloadUrl(String storagePath);
}

/// [AsyncVoiceUploader] backed by Firebase Storage.
class FirebaseVoiceUploader implements AsyncVoiceUploader {
  FirebaseVoiceUploader({FirebaseStorage? storage})
    : _storage = storage ?? FirebaseStorage.instance;

  final FirebaseStorage _storage;

  @override
  Future<void> upload(String storagePath, File file) => _storage
      .ref(storagePath)
      .putFile(file, SettableMetadata(contentType: 'audio/wav'));

  @override
  Future<String?> downloadUrl(String storagePath) async {
    try {
      return await _storage.ref(storagePath).getDownloadURL();
    } catch (_) {
      return null;
    }
  }
}

/// A recorded voice message waiting for (or in) delivery.
@immutable
class QueuedVoiceMessage {
  const QueuedVoiceMessage({
    required this.jobId,
    required this.fileName,
    this.storagePath = '',
    this.submitted = false,
    required this.createdAt,
  });

  /// The `job_id` of this send. Stable for the message's whole life, so
  /// every attempt to deliver it is idempotent server-side — a flush after
  /// a dropped connection can never transcribe (or bill) the clip twice.
  final String jobId;

  /// The clip's file name inside the queue's clips directory (the directory
  /// itself is resolved at runtime, never persisted).
  final String fileName;

  /// `uploads/{uid}/…` once uploaded, else empty (still phone-local).
  final String storagePath;

  /// True once `POST /voice/async` accepted this message — from here the job
  /// watcher owns it, and a restart re-watches instead of resubmitting (the
  /// submit is idempotent server-side, so a lost flag only costs a join).
  final bool submitted;

  final DateTime createdAt;

  QueuedVoiceMessage withStoragePath(String path) => QueuedVoiceMessage(
    jobId: jobId,
    fileName: fileName,
    storagePath: path,
    submitted: submitted,
    createdAt: createdAt,
  );

  QueuedVoiceMessage withSubmitted() => QueuedVoiceMessage(
    jobId: jobId,
    fileName: fileName,
    storagePath: storagePath,
    submitted: true,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': jobId,
    'file': fileName,
    'storage_path': storagePath,
    'submitted': submitted,
    'created_at': createdAt.toIso8601String(),
  };

  static QueuedVoiceMessage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final file = raw['file'];
    if (id is! String || id.isEmpty || file is! String || file.isEmpty) {
      return null;
    }
    return QueuedVoiceMessage(
      jobId: id,
      fileName: file,
      storagePath: raw['storage_path'] as String? ?? '',
      submitted: raw['submitted'] == true,
      createdAt:
          DateTime.tryParse(raw['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// Voice messages recorded while offline (or mid-send when the app died),
/// held on the phone until they can go.
///
/// Clips live in the app documents directory (surviving restarts); only
/// their metadata is in [SharedPreferences], per account. Delivery —
/// upload, `POST /voice/async`, then watching the job doc until Ayma's
/// reply lands — runs in order, oldest first, and stops at the first item
/// that cannot go (it stays queued, and so does everything behind it).
/// A flush runs on [enqueue], on [activate], and whenever the
/// [ConnectionHeartbeat] climbs back out of [ConnectionQuality.offline].
///
/// The finished turn is adopted into the [TranscriptStore] exactly as the
/// server persisted it (same transcript, same job id), so a later history
/// reload dedups instead of doubling it.
class AsyncVoiceQueue extends ChangeNotifier {
  AsyncVoiceQueue({
    ApiClient? api,
    TranscriptStore? store,
    String? sessionId,
    String? Function()? currentUid,
    AsyncVoiceUploader? uploader,
    FirebaseFirestore? firestore,
    ConnectionHeartbeat? heartbeat,
    Future<Directory> Function()? clipsDir,
    this._watchRetryDelay = const Duration(seconds: 10),
  }) : _apiOverride = api,
       _storeOverride = store,
       _sessionIdOverride = sessionId,
       _currentUid = currentUid ?? _firebaseUid,
       _uploaderOverride = uploader,
       _firestoreOverride = firestore,
       _heartbeatOverride = heartbeat,
       _clipsDirOverride = clipsDir;

  static String? _firebaseUid() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null; // Firebase not initialised (unit tests): nothing to load.
    }
  }

  /// The app-wide queue, delivering into the shared [AymaSession] transcript.
  static final AsyncVoiceQueue instance = AsyncVoiceQueue();

  static const _keyPrefix = 'async_voice_queue_v1:';
  static const _clipsDirName = 'async_voice_clips';

  final ApiClient? _apiOverride;
  final TranscriptStore? _storeOverride;
  final String? _sessionIdOverride;
  final String? Function() _currentUid;
  final AsyncVoiceUploader? _uploaderOverride;
  final FirebaseFirestore? _firestoreOverride;
  final ConnectionHeartbeat? _heartbeatOverride;
  final Future<Directory> Function()? _clipsDirOverride;

  /// Delay before a watcher failure is reconciled through the idempotent
  /// submit (see [_scheduleReconcile]). Injectable for tests.
  final Duration _watchRetryDelay;

  late final ApiClient _api = _apiOverride ?? ApiClient();
  TranscriptStore get _store => _storeOverride ?? AymaSession.instance.store;
  String get _sessionId => _sessionIdOverride ?? AymaSession.instance.sessionId;
  AsyncVoiceUploader get _uploader =>
      _uploaderOverride ?? FirebaseVoiceUploader();
  FirebaseFirestore get _db => _firestoreOverride ?? FirebaseFirestore.instance;
  ConnectionHeartbeat get _heartbeat =>
      _heartbeatOverride ?? ConnectionHeartbeat.instance;

  final List<QueuedVoiceMessage> _items = [];
  final Map<String, String> _jobStatuses = {};
  final Map<String, StreamSubscription<DocumentSnapshot>> _watchers = {};

  /// Jobs whose Firestore watch has failed (permission-denied, offline
  /// flap): they are reconciled through the submit fallback in [flush],
  /// never blindly re-watched (see [_reapWatchers]).
  final Set<String> _watchFailed = {};
  Timer? _reconcileTimer;
  String? _loadedUid;
  bool _flushing = false;
  bool _listening = false;
  String? _sendingId;
  bool _disposed = false;

  /// Every message still waiting, oldest first — including the one whose
  /// delivery is in flight.
  List<QueuedVoiceMessage> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;

  /// The messages to show as "waiting" bubbles: every item, including the
  /// one whose delivery is in flight — unlike the text queue, delivery never
  /// pre-adds a transcript turn (there is no transcript until the job
  /// finishes), so excluding it would blink the bubble out mid-upload.
  List<QueuedVoiceMessage> get waiting => List.unmodifiable(_items);

  /// The latest known job status per watched job (`transcribing`,
  /// `thinking`, `speaking`, `done`, `error`) — drives the loader stage.
  Map<String, String> get jobStatuses => Map.unmodifiable(_jobStatuses);

  /// Loader stage for [jobId] into `AymaLoaderLines.asyncVoice`: 0 while
  /// the clip uploads, 1 transcribing, 2 thinking, 3 speaking/settling.
  int stageFor(String jobId) {
    if (_sendingId == jobId && !_jobStatuses.containsKey(jobId)) return 0;
    return switch (_jobStatuses[jobId]) {
      'transcribing' => 1,
      'thinking' => 2,
      'speaking' || 'done' || 'error' => 3,
      _ => 0,
    };
  }

  /// True while any item is uploading, submitted, or watched — the UI keeps
  /// its loader up until this falls.
  bool get hasActiveWork =>
      _sendingId != null || _watchers.isNotEmpty || _jobStatuses.isNotEmpty;

  Future<Directory> _clipsDir() async {
    final override = _clipsDirOverride;
    final base = override != null
        ? await override()
        : await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_clipsDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Load the signed-in account's persisted queue (once per account),
  /// re-watch anything already submitted, and flush on reconnect.
  Future<void> activate() async {
    if (!_listening) {
      _listening = true;
      _heartbeat.listenable.addListener(_onConnectionChanged);
    }
    final uid = _currentUid();
    if (uid == null || uid.isEmpty || uid == _loadedUid) return;
    _loadedUid = uid;
    _items.clear();
    try {
      final raw = (await SharedPreferences.getInstance()).getString(
        '$_keyPrefix$uid',
      );
      if (raw != null && raw.isNotEmpty && _loadedUid == uid) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final dir = await _clipsDir();
          for (final m
              in decoded
                  .map(QueuedVoiceMessage.fromJson)
                  .whereType<QueuedVoiceMessage>()) {
            // A queued row whose clip file is gone (user cleared data, a
            // failed move) can never be delivered — drop it rather than
            // wedge the flush behind an item that always fails.
            if (await File('${dir.path}/${m.fileName}').exists()) {
              _items.add(m);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('AsyncVoiceQueue load failed: $e');
    }
    notifyListeners();
    _reconcileSubmitted();
  }

  void _onConnectionChanged() {
    if (_heartbeat.state != ConnectionQuality.offline) {
      _reconcileSubmitted();
    }
  }

  /// Trigger reconciliation of any submitted-but-unresolved jobs across
  /// connectivity restore or queue transitions. Dropping their watchers and
  /// marking them watch-failed forces the flush pass to query the idempotent
  /// submit directly instead of relying on a potentially dead/silent watch
  /// (Scout note 111).
  void _reconcileSubmitted() {
    for (final m in _items) {
      if (m.submitted) {
        _watchFailed.add(m.jobId);
        unawaited(_stopWatching(m.jobId));
      }
    }
    unawaited(flush());
  }

  /// Hold a fresh recording ([recordedFile], any path) for delivery under
  /// [jobId]. The file is moved into the queue's clips directory first, so
  /// a crash between recording and upload never loses it.
  Future<QueuedVoiceMessage> enqueue(String jobId, File recordedFile) async {
    final existing = _items.where((m) => m.jobId == jobId).firstOrNull;
    if (existing != null) {
      unawaited(flush());
      return existing;
    }
    final dir = await _clipsDir();
    final target = File('${dir.path}/$jobId.wav');
    try {
      if (await target.exists()) await target.delete();
      await recordedFile.rename(target.path);
    } catch (_) {
      // Cross-volume move (or a test double): fall back to copy + delete.
      try {
        await recordedFile.copy(target.path);
        await recordedFile.delete();
      } catch (e) {
        debugPrint('AsyncVoiceQueue stage failed: $e');
        rethrow;
      }
    }
    final item = QueuedVoiceMessage(
      jobId: jobId,
      fileName: '$jobId.wav',
      createdAt: DateTime.now(),
    );
    _items.add(item);
    notifyListeners();
    await _persist();
    // Queue transition: reconcile any earlier submitted-but-unresolved job.
    for (final m in _items) {
      if (m.jobId != item.jobId && m.submitted) {
        _watchFailed.add(m.jobId);
        unawaited(_stopWatching(m.jobId));
      }
    }
    unawaited(flush());
    return item;
  }

  /// Drop a waiting message the user no longer wants sent. A message whose
  /// job is already submitted keeps running server-side (its reply lands
  /// in history on the next load) — cancelling only stops the local watch.
  Future<void> cancel(String jobId) async {
    if (jobId == _sendingId) return;
    final before = _items.length;
    _items.removeWhere((m) => m.jobId == jobId);
    if (_items.length == before) return;
    await _stopWatching(jobId);
    _watchFailed.remove(jobId);
    _jobStatuses.remove(jobId);
    if (_items.isEmpty) {
      _reconcileTimer?.cancel();
      _reconcileTimer = null;
    }
    notifyListeners();
    await _persist();
    await _deleteClip(jobId);
  }

  /// Deliver queued messages in order. Stops at the first one that cannot
  /// go (offline, upload failed, submit failed) — it stays queued, and so
  /// does everything behind it. Items the job watcher already owns are
  /// skipped, never resubmitted: their completion arrives via the watcher.
  Future<void> flush() async {
    if (_flushing || _disposed) return;
    _flushing = true;
    try {
      _reapWatchers();
      for (final item in List.of(_items)) {
        if (_disposed) return;
        if (_heartbeat.state == ConnectionQuality.offline) return;
        // Adopted (or cancelled) while this flush ran.
        if (!_items.any((m) => m.jobId == item.jobId)) continue;
        // Submitted — the watcher owns it now, unless its watch failed.
        if (_watchers.containsKey(item.jobId) &&
            !_watchFailed.contains(item.jobId)) {
          continue;
        }
        if (!await _deliver(item)) return;
      }
    } finally {
      _flushing = false;
    }
  }

  /// Re-watch submitted jobs left unwatched by a restart — a submit that
  /// landed server-side but never got its watcher (kill between the two)
  /// would otherwise sit silent forever. Uploaded-but-never-submitted
  /// items are NOT watched here: the flush below submits them (idempotent
  /// server-side) and the watcher attaches on that path instead. Jobs in
  /// [_watchFailed] are skipped for the opposite reason: their flush-loop
  /// turn goes through [_deliver], whose idempotent resubmit reconciles
  /// them from the stored outcome.
  void _reapWatchers() {
    for (final m in _items) {
      if (m.submitted &&
          !_watchers.containsKey(m.jobId) &&
          !_watchFailed.contains(m.jobId)) {
        unawaited(_watch(m));
      }
    }
  }

  Future<bool> _deliver(QueuedVoiceMessage item) async {
    final uid = _loadedUid ?? _currentUid();
    if (uid == null || uid.isEmpty) return false;
    var current = item;
    _sendingId = item.jobId;
    if (!_disposed) notifyListeners();
    try {
      final dir = await _clipsDir();
      final file = File('${dir.path}/${item.fileName}');
      if (!await file.exists()) {
        await _remove(item); // undeliverable — never wedge the queue
        return true;
      }
      if (current.storagePath.isEmpty) {
        final path = 'uploads/$uid/async_voice/${item.jobId}.wav';
        await _uploader.upload(path, file);
        current = current.withStoragePath(path);
        _replace(item, current);
        await _persist();
      }
      final window = _store.wireTurns();
      final submit = await _api.submitVoiceMessage(
        jobId: current.jobId,
        storagePath: current.storagePath,
        sessionId: _sessionId,
        recentTurns: window,
      );
      current = current.withSubmitted();
      _replace(item, current);
      await _persist();
      if (submit.status == 'done') {
        await _adoptDone(
          current,
          file,
          _SubmitPayload(
            transcript: submit.transcript,
            replyText: submit.replyText,
            replyAudioUrl: submit.replyAudioUrl,
            tools: submit.tools,
            imageUrl: submit.imageUrl,
          ),
        );
        await _remove(current);
        return true;
      }
      if (submit.status == 'error') {
        await _adoptError(
          current,
          file,
          transcript: submit.transcript,
          error: '',
          usageCapped: false,
        );
        await _remove(current);
        return true;
      }
      if (submit.status.isNotEmpty) {
        _jobStatuses[current.jobId] = submit.status;
        if (!_disposed) notifyListeners();
      }
      if (_watchFailed.contains(current.jobId)) {
        // The watch failed or was dropped for reconcile: re-arm the delayed
        // reconcile until the server reports a terminal state (Scout note 111).
        _scheduleReconcile();
      } else {
        await _watch(current);
      }
      return true;
    } catch (e) {
      debugPrint('AsyncVoiceQueue delivery failed: $e');
      if (_watchFailed.contains(current.jobId)) {
        _scheduleReconcile();
      }
      return false;
    } finally {
      _sendingId = null;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _watch(QueuedVoiceMessage item) async {
    final uid = _loadedUid ?? _currentUid();
    if (uid == null || uid.isEmpty || _watchers.containsKey(item.jobId)) return;
    final ref = _db.doc('users/$uid/async_voice_jobs/${item.jobId}');
    _jobStatuses.putIfAbsent(item.jobId, () => 'transcribing');
    if (!_disposed) notifyListeners();
    _watchers[item.jobId] = ref.snapshots().listen(
      (snap) => unawaited(_onJobSnap(item, snap)),
      onError: (Object e) {
        // The watch is dead (permission-denied, offline flap): drop it and
        // mark the job watch-failed so the reconcile flush below goes
        // through the idempotent submit — whose answer carries a finished
        // job's full payload — instead of re-watching blind. Without this
        // a job could sit at "Hearing you out…" forever with its reply
        // already written server-side (Scout note 109, 2026-11-05).
        debugPrint('AsyncVoiceQueue watch failed: $e');
        _watchFailed.add(item.jobId);
        unawaited(_stopWatching(item.jobId));
        _scheduleReconcile();
      },
    );
  }

  /// Arm the delayed reconcile flush after a watcher failure. One timer
  /// at a time; the flush itself re-arms (via the next watch error) if the
  /// job is still running and its fresh watch fails again.
  void _scheduleReconcile() {
    if (_disposed || _reconcileTimer != null || _items.isEmpty) return;
    _reconcileTimer = Timer(_watchRetryDelay, () {
      _reconcileTimer = null;
      unawaited(flush());
    });
  }

  Future<void> _stopWatching(String jobId) async {
    final sub = _watchers.remove(jobId);
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
  }

  Future<void> _onJobSnap(
    QueuedVoiceMessage item,
    DocumentSnapshot snap,
  ) async {
    if (_disposed) return;
    // A snapshot arrived: the watch path is healthy for this job again.
    _watchFailed.remove(item.jobId);
    final data = snap.data();
    if (data is! Map) return;
    final m = data.cast<String, dynamic>();
    final status = m['status'] as String? ?? '';
    if (status.isEmpty || status == 'received') return;
    _jobStatuses[item.jobId] = status;
    notifyListeners();
    if (status != 'done' && status != 'error') return;
    await _stopWatching(item.jobId);
    final dir = await _clipsDir();
    final file = File('${dir.path}/${item.fileName}');
    if (status == 'done') {
      await _adoptDone(
        item,
        file,
        _SubmitPayload(
          transcript: m['transcript'] as String? ?? '',
          replyText: m['reply_text'] as String? ?? '',
          replyAudioUrl: m['reply_audio_url'] as String? ?? '',
          tools: ((m['tools'] as List?) ?? const [])
              .map((e) => e.toString())
              .where((s) => s.isNotEmpty)
              .toList(),
          imageUrl: m['image_url'] as String? ?? '',
        ),
      );
    } else {
      await _adoptError(
        item,
        file,
        transcript: m['transcript'] as String? ?? '',
        error: m['error'] as String? ?? '',
        usageCapped: m['usage_capped'] == true,
      );
    }
    _jobStatuses.remove(item.jobId);
    await _remove(item);
  }

  /// Show the user's recorded turn: the local clip plays instantly, and the
  /// resolved remote URL swaps in when it lands (so the bubble keeps
  /// playing after the local file is cleaned up).
  Future<void> _adoptUserTurn(
    QueuedVoiceMessage item,
    File file,
    String transcript,
  ) async {
    final store = _store;
    final turn = store.addTurn(
      TurnRole.user,
      transcript,
      TurnSource.voice,
      audioFile: await file.exists() ? file : null,
    );
    if (item.storagePath.isEmpty) return;
    final userUrl = await _uploader.downloadUrl(item.storagePath);
    if (userUrl != null) store.updateTurnAudio(turn, userUrl);
  }

  /// Show a finished turn — unless the transcript (loaded from history)
  /// already has it.
  Future<void> _adoptDone(
    QueuedVoiceMessage item,
    File file,
    _SubmitPayload p,
  ) async {
    final store = _store;
    final transcript = p.transcript.trim();
    final reply = p.replyText.trim();
    if (transcript.isEmpty || reply.isEmpty) return;
    final alreadyShown = store.turns.reversed
        .take(10)
        .any((t) => t.role == TurnRole.ayma && t.isFinal && t.text == reply);
    if (alreadyShown) return;
    await _adoptUserTurn(item, file, transcript);
    store.addTurn(
      TurnRole.ayma,
      reply,
      TurnSource.voice,
      tools: p.tools,
      imageUrl: p.imageUrl.isEmpty ? null : p.imageUrl,
      audioUrl: p.replyAudioUrl.isEmpty ? null : p.replyAudioUrl,
    );
  }

  /// Show a failed job honestly: the user's turn (only when the server
  /// transcribed it — matching the persisted row) plus Ayma's error copy.
  /// A usage-capped job resolves to the same "reload credits" card text
  /// chat uses, so the Plan upsell surfaces from here too.
  Future<void> _adoptError(
    QueuedVoiceMessage item,
    File file, {
    required String transcript,
    required String error,
    required bool usageCapped,
  }) async {
    final store = _store;
    final copy = error.trim().isEmpty
        ? "Ayma couldn't answer that voice message. Please try again."
        : error.trim();
    if (transcript.trim().isNotEmpty) {
      await _adoptUserTurn(item, file, transcript.trim());
    }
    store.addPending('Thinking…');
    store.resolvePending(copy, capped: usageCapped);
  }

  void _replace(QueuedVoiceMessage old, QueuedVoiceMessage replacement) {
    final i = _items.indexWhere((m) => m.jobId == old.jobId);
    if (i != -1) _items[i] = replacement;
  }

  /// Removing a job drops ALL of its per-job state — the list entry, the
  /// loader status the watcher set, and any watch-failed mark. The
  /// controller idles exactly when the status map no longer holds the job
  /// (see AsyncVoiceController._onQueueChanged), so a removal that left the
  /// status behind stranded the controller in `working` forever: the
  /// reconcile path in [_deliver] adopts a finished job and removes it
  /// without ever hearing from the watcher that set the status, and every
  /// later hold-to-record then hit the idle guard and did nothing
  /// (Scout note 110, 2026-11-05).
  Future<void> _remove(QueuedVoiceMessage item) async {
    _items.removeWhere((m) => m.jobId == item.jobId);
    _jobStatuses.remove(item.jobId);
    _watchFailed.remove(item.jobId);
    if (_items.isEmpty) {
      _reconcileTimer?.cancel();
      _reconcileTimer = null;
    }
    if (!_disposed) notifyListeners();
    await _persist();
    await _deleteClip(item.jobId);
  }

  Future<void> _deleteClip(String jobId) async {
    try {
      final dir = await _clipsDir();
      final file = File('${dir.path}/$jobId.wav');
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('AsyncVoiceQueue clip delete failed: $e');
    }
  }

  Future<void> _persist() async {
    final uid = _loadedUid;
    if (uid == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_items.isEmpty) {
        await prefs.remove('$_keyPrefix$uid');
      } else {
        await prefs.setString(
          '$_keyPrefix$uid',
          jsonEncode([for (final m in _items) m.toJson()]),
        );
      }
    } catch (e) {
      debugPrint('AsyncVoiceQueue persist failed: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    if (_listening) {
      _listening = false;
      _heartbeat.listenable.removeListener(_onConnectionChanged);
    }
    for (final sub in _watchers.values) {
      unawaited(sub.cancel());
    }
    _watchers.clear();
    super.dispose();
  }
}

/// A finished job's thread payload, from either the submit answer or the
/// watched job doc — both shapes carry the same fields.
class _SubmitPayload {
  const _SubmitPayload({
    required this.transcript,
    required this.replyText,
    required this.replyAudioUrl,
    required this.tools,
    required this.imageUrl,
  });

  final String transcript;
  final String replyText;
  final String replyAudioUrl;
  final List<String> tools;
  final String imageUrl;
}
