import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show BytesBuilder;

import 'package:steadfast_downloader/src/engine/download_record.dart';
import 'package:steadfast_downloader/src/engine/response_check.dart';
import 'package:steadfast_downloader/src/engine/retry_policy.dart';
import 'package:steadfast_downloader/src/engine/working_files.dart';
import 'package:http/http.dart' as http;

/// How a streaming download ended.
enum DownloadOutcome {
  completed,
  cancelled,
  failed,

  /// The link has expired, or a page came in place of the file: the `.part`
  /// is kept for a fresh link.
  needsFreshLink,

  /// The connection or the server failed for a while with no bytes coming:
  /// the `.part` is committed and kept, to go on from later.
  interrupted,

  /// The disk is full: the `.part` is committed and kept, to go on from once
  /// there is room. Never tried again by itself.
  diskFull,
}

/// How a download ended, with the bytes on disk and any error.
class DownloadResult {
  final DownloadOutcome outcome;
  final int bytesOnDisk;
  final int totalBytes;
  final Object? error;
  const DownloadResult(
    this.outcome, {
    this.bytesOnDisk = 0,
    this.totalBytes = 0,
    this.error,
  });
}

/// A new link for a download whose link expired, and the headers it needs
/// (a host's new cookie); with none, the run's headers are kept.
class FreshLink {
  const FreshLink(this.url, {this.headers = const {}});

  final String url;
  final Map<String, String> headers;
}

/// Streams a file into its `.part` and continues it with a Range request,
/// never throwing a partial away but one [partialIsValid] turns down.
///
/// [log] receives one line per step; [partialIsValid] is the app's check of
/// a partial before it is gone on from (a page saved in place of the file
/// fails it). Both default to nothing and to accepting every partial.
///
/// The bytes on disk are committed to the record beside the `.part` every
/// `commitEveryBytes` or `commitEvery`, and whenever a run stops.
///
/// A connection with no bytes for `stallTimeout` (headers included) is
/// dropped. A failed connection or a busy server is tried again after a
/// full-jitter wait from `retryBase` up to `retryCap`; after `quietAttempts`
/// tries with no bytes the run is [DownloadOutcome.interrupted].
///
/// [adoptExistingFile] takes a file already at the final path, with no
/// `.part` beside it, as a partial to go on from: for an app whose older
/// downloader kept partials under the final name. Off by default, when such a
/// file is left alone and replaced once the download completes.
///
/// [clientFactory] makes the HTTP client for each attempt (a proxy, your own
/// certificate checks); the engine closes it when the attempt ends.
class StreamingDownloader {
  StreamingDownloader({
    void Function(String line)? log,
    Future<bool> Function(File partial)? partialIsValid,
    int commitEveryBytes = 8 * 1024 * 1024,
    Duration commitEvery = const Duration(seconds: 5),
    Duration stallTimeout = const Duration(seconds: 30),
    Duration retryBase = const Duration(seconds: 1),
    Duration retryCap = const Duration(minutes: 2),
    int quietAttempts = 5,
    bool adoptExistingFile = false,
    http.Client Function()? clientFactory,
    Random? random,
  }) : _log = log ?? _noLog,
       _partialIsValid = partialIsValid ?? _anyPartial,
       _commitEveryBytes = commitEveryBytes,
       _commitEvery = commitEvery,
       _stallTimeout = stallTimeout,
       _retryBase = retryBase,
       _retryCap = retryCap,
       _quietAttempts = quietAttempts,
       _adoptExistingFile = adoptExistingFile,
       _clientFactory = clientFactory ?? http.Client.new,
       _random = random ?? Random();

  final void Function(String line) _log;
  final Future<bool> Function(File partial) _partialIsValid;
  final int _commitEveryBytes;
  final Duration _commitEvery;
  final Duration _stallTimeout;
  final Duration _retryBase;
  final Duration _retryCap;
  final int _quietAttempts;
  final bool _adoptExistingFile;
  final http.Client Function() _clientFactory;
  final Random _random;

  /// The longest a server's `Retry-After` is waited for within a run.
  static const _busyCap = Duration(minutes: 10);

  /// Bytes come in small chunks and go to disk in blocks of this size;
  /// progress is reported at most this often.
  static const _writeBlock = 1 << 20;
  static const _progressEvery = Duration(milliseconds: 150);

  static void _noLog(String line) {}
  static Future<bool> _anyPartial(File partial) async => true;

  final Map<String, _Job> _jobs = {};

  bool isActive(String taskId) => _jobs.containsKey(taskId);

  /// Signal a transfer to stop; completes once it has fully unwound, at
  /// once even while it waits for a fresh link or out a back-off.
  Future<void> cancel(String taskId) {
    final job = _jobs[taskId];
    if (job == null) return Future.value();
    job.stop();
    return job.done.future;
  }

  /// Stop every transfer; completes once each has committed its offset and
  /// let its file go (the app's save before it exits).
  Future<void> cancelAll() =>
      Future.wait([for (final taskId in _jobs.keys.toList()) cancel(taskId)]);

  /// Stream [url] into [absFilePath], resuming from any valid partial.
  ///
  /// [freshLink] gets a new link when this one has expired or answers with a
  /// page: asked twice at most a run; without it, or when it gives none, the
  /// run ends in [DownloadOutcome.needsFreshLink], the `.part` kept. A
  /// cancel doesn't wait for it: the run ends cancelled, and what the lookup
  /// brings later is not used.
  ///
  /// [onWaiting] hears each back-off before it is waited out: how long, and
  /// the error that caused it ([ServerBusy] for a busy server), so the app
  /// can say the download is waiting rather than show it frozen.
  Future<DownloadResult> run({
    required String taskId,
    required String url,
    required String absFilePath,
    required Map<String, String> headers,
    required void Function(int bytesOnDisk, int totalBytes) onProgress,
    Future<FreshLink?> Function()? freshLink,
    void Function(Duration wait, Object error)? onWaiting,
  }) async {
    // Registered before the run it replaces has stopped: a run or a cancel
    // that comes meanwhile finds this one, so two runs never share a .part.
    final prior = _jobs[taskId];
    final job = _Job();
    _jobs[taskId] = job;
    if (prior != null) {
      prior.stop();
      await prior.done.future;
    }
    http.Client? client;
    RandomAccessFile? raf;
    Timer? watchdog;
    final file = File(partialPathFor(absFilePath));
    final destination = File(absFilePath);
    var received = 0;
    var total = 0;
    // A stop or a failure reports what the .part holds so far.
    DownloadResult ended(DownloadOutcome outcome, [Object? error]) =>
        DownloadResult(
          outcome,
          bytesOnDisk: received,
          totalBytes: total,
          error: error,
        );
    // The app's callbacks: one that throws is the app's bug, logged, never
    // the download's failure.
    void progress(int bytesOnDisk, int totalBytes) {
      try {
        onProgress(bytesOnDisk, totalBytes);
      } catch (e) {
        _log('task=$taskId onProgress threw: $e');
      }
    }

    Object? lastError;
    try {
      // Stopped while the run before it unwound.
      if (job.cancelled) return ended(DownloadOutcome.cancelled);
      await file.parent.create(recursive: true);
      // A partial an older downloader kept under the file's own name.
      if (_adoptExistingFile &&
          !await file.exists() &&
          await destination.exists()) {
        await destination.rename(file.path);
      }
      var existing = await file.exists() ? await file.length() : 0;

      if (existing > 0 && !await _partialIsValid(file)) {
        _log(
          'task=$taskId partial turned down by the check; '
          'discarding ${_mb(existing)} and restarting',
        );
        try {
          await file.delete();
        } catch (_) {}
        existing = 0;
      }

      // Bytes past the committed offset may be torn by a crash between a
      // write and its commit: they are cut. A .part with no record (an
      // older version's) is trusted at its length.
      final recordFile = File(recordPathFor(absFilePath));
      var record =
          (await DownloadRecord.read(recordFile))?.copyWith(url: url) ??
          DownloadRecord(url: url, committedOffset: existing);
      if (existing > record.committedOffset) {
        final cut = await file.open(mode: FileMode.append);
        try {
          await cut.truncate(record.committedOffset);
        } finally {
          await cut.close();
        }
        _log(
          'task=$taskId cut ${_mb(existing - record.committedOffset)} '
          'past the committed offset',
        );
        existing = record.committedOffset;
      } else if (existing < record.committedOffset) {
        record = record.copyWith(committedOffset: existing);
      }
      // What the .part holds, reported even by a run stopped before its
      // first request.
      received = existing;
      var currentUrl = url;
      var currentHeaders = headers;
      var freshLinks = 0;
      var afterFreshLink = false;
      // An expired link or a page in place of the file: a fresh link.
      Future<bool> renewLink(String reason) async {
        if (freshLink == null || freshLinks >= 2 || job.cancelled) {
          return false;
        }
        freshLinks++;
        try {
          // A cancel answers at once: the lookup is left to finish on its
          // own, and its link isn't used.
          final lookup = freshLink();
          lookup.ignore();
          final next = await Future.any<FreshLink?>([
            lookup,
            job.stopped.future.then((_) => null),
          ]);
          if (job.cancelled) return false;
          if (next == null || next.url.isEmpty) return false;
          _log('task=$taskId $reason: a fresh link (#$freshLinks)');
          currentUrl = next.url;
          if (next.headers.isNotEmpty) currentHeaders = next.headers;
          record = record.copyWith(url: next.url);
          afterFreshLink = true;
          return true;
        } on ServerBusy {
          // The app's lookup failed on the way: tried again with this run's
          // backoff, not counted as a renewal.
          freshLinks--;
          rethrow;
        } catch (e) {
          _log('task=$taskId $reason: no fresh link: $e');
          return false;
        }
      }

      Future<void> commit(int offset) async {
        record = record.copyWith(committedOffset: offset);
        try {
          await record.write(recordFile);
        } catch (e) {
          _log('task=$taskId could not commit ${_mb(offset)}: $e');
        }
      }

      var quiet = 0;
      var fromZeroAsks = 0;
      while (true) {
        if (job.cancelled) {
          return ended(DownloadOutcome.cancelled);
        }
        try {
          await raf?.close();
        } catch (_) {}
        raf = null;
        try {
          client?.close();
        } catch (_) {}

        existing = await file.exists() ? await file.length() : 0;
        received = existing;
        final attemptStartBytes = existing;
        final pending = BytesBuilder(copy: false);
        // The bytes held in memory go to the .part; only then do they count.
        Future<void> drain() async {
          final open = raf;
          if (pending.isEmpty || open == null) return;
          final block = pending.takeBytes();
          await open.writeFrom(block);
          received += block.length;
        }

        client = _clientFactory();
        job.client = client;
        // A cancel while this attempt got ready closed the client before
        // this one: it ends here, not after the server answers.
        if (job.cancelled) return ended(DownloadOutcome.cancelled);
        var streamStarted = false;

        try {
          final uri = Uri.parse(currentUrl);
          // No bytes (or no headers) for the stall timeout drops the
          // connection: Dart has no read timeout, and a half-open one hangs.
          final abort = Completer<void>();
          void armWatchdog() {
            watchdog?.cancel();
            watchdog = Timer(_stallTimeout, () {
              if (!abort.isCompleted) abort.complete();
            });
          }

          armWatchdog();
          final req =
              http.AbortableRequest(
                  'GET',
                  uri,
                  abortTrigger: Future.any([abort.future, job.stopped.future]),
                )
                ..followRedirects = true
                ..headers.addAll({
                  for (final MapEntry(:key, :value) in currentHeaders.entries)
                    if (!_ownedHeaders.contains(key.toLowerCase())) key: value,
                })
                ..headers.addAll(
                  requestHeaders(
                    offset: existing,
                    host: uri.host,
                    record: record,
                  ),
                );

          _log(
            'task=$taskId start existing=${_mb(existing)} '
            'resume=${existing > 0 ? 'yes' : 'no'}',
          );

          final resp = await client.send(req);
          if (job.cancelled) {
            return DownloadResult(
              DownloadOutcome.cancelled,
              bytesOnDisk: existing,
            );
          }
          final h = resp.headers;
          _log(
            'task=$taskId answer ${resp.statusCode} '
            '${h['content-type'] ?? 'no type'}'
            '${h.containsKey('content-encoding') ? ' ${h['content-encoding']}' : ''}',
          );

          final int startAt;
          final FileMode mode;
          // Only the first answer after a renewal judges the fresh link: a
          // link that expires again later in the run is renewed again, up
          // to the run's two.
          final justRenewed = afterFreshLink;
          afterFreshLink = false;
          switch (judgeResponse(
            offset: existing,
            status: resp.statusCode,
            headers: resp.headers,
            record: record,
            afterFreshLink: justRenewed,
          )) {
            case AlreadyComplete():
              progress(existing, existing);
              return await _finish(
                taskId,
                file,
                destination,
                recordFile,
                existing,
                existing,
              );
            case AppendAt(total: final whole):
              startAt = existing;
              final length = resp.contentLength;
              total = whole ?? (length != null ? existing + length : 0);
              mode = FileMode.writeOnlyAppend;
            case WriteFromStart(total: final whole):
              if (existing > 0) {
                _log('task=$taskId the whole file came back; from the start');
              }
              startAt = 0;
              total = whole ?? 0;
              mode = FileMode.writeOnly;
            case RequestFromZero(:final reason):
              if (++fromZeroAsks > 2) {
                _log('task=$taskId $reason, again; giving up');
                return ended(DownloadOutcome.failed, HttpException(reason));
              }
              _log('task=$taskId $reason; asking again from zero');
              try {
                await file.delete();
              } catch (_) {}
              await commit(0);
              continue;
            case FreshLinkNeeded(:final reason):
              if (await renewLink(reason)) continue;
              if (job.cancelled) return ended(DownloadOutcome.cancelled);
              _log('task=$taskId needs a fresh link: $reason; .part kept');
              return ended(
                DownloadOutcome.needsFreshLink,
                HttpException(reason),
              );
            case TryAgain(:final reason, :final after):
              throw ServerBusy(reason, after: after);
            case Refused(:final reason):
              _log('task=$taskId refused: $reason at ${_mb(received)}');
              return ended(DownloadOutcome.failed, HttpException(reason));
          }
          record = recordAfter(
            record,
            host: uri.host,
            headers: resp.headers,
            total: total > 0 ? total : null,
          );
          streamStarted = true;

          var sniffed = false;
          var pageInstead = false;
          var uncommitted = 0;
          var committedAt = DateTime.now();
          var reportedAt = DateTime.now();
          await for (final chunk in resp.stream) {
            armWatchdog();
            if (job.cancelled) {
              _log('task=$taskId cancelled at ${_mb(received)}');
              final open = raf;
              if (open != null) {
                await drain();
                await open.flush();
                await commit(received);
              }
              return ended(DownloadOutcome.cancelled);
            }
            if (!sniffed) {
              // The .part is touched only once the body is the file.
              sniffed = true;
              if (looksLikeHtml(chunk)) {
                pageInstead = true;
                break;
              }
              raf = await file.open(mode: mode);
              received = startAt;
              if (mode == FileMode.writeOnly) await commit(0);
              progress(received, total);
            }
            pending.add(chunk);
            uncommitted += chunk.length;
            if (pending.length >= _writeBlock) await drain();
            final now = DateTime.now();
            if (uncommitted >= _commitEveryBytes ||
                now.difference(committedAt) >= _commitEvery) {
              await drain();
              await raf!.flush();
              await commit(received);
              uncommitted = 0;
              committedAt = now;
            }
            if (now.difference(reportedAt) >= _progressEvery) {
              progress(received + pending.length, total);
              reportedAt = now;
            }
          }
          if (pageInstead) {
            const reason = 'a page in place of the file';
            if (await renewLink(reason)) continue;
            if (job.cancelled) return ended(DownloadOutcome.cancelled);
            _log('task=$taskId $reason; .part kept');
            return ended(
              DownloadOutcome.needsFreshLink,
              const HttpException(reason),
            );
          }
          // Not one byte came: never a file, and the .part is never opened
          // for it (writing from the start would empty it). Tried again as a
          // cut body is.
          if (!sniffed) throw const HttpException('the body was empty');
          final open = raf!;
          await drain();
          // The body ended by itself, but a body with no length ends cleanly
          // wherever it is cut: by a cancel closing the client, or short of
          // the size it said. Neither is the file; the catch commits and goes
          // on or stops.
          if (job.cancelled || (total > 0 && received < total)) {
            throw HttpException('the body ended at $received of $total');
          }
          await open.flush();
          await open.close();
          raf = null;
          progress(received, total > 0 ? total : received);
          _log('task=$taskId completed ${_mb(received)}/${_mb(total)}');
          return await _finish(
            taskId,
            file,
            destination,
            recordFile,
            received,
            total > 0 ? total : received,
          );
        } catch (e) {
          watchdog?.cancel();
          // A cancel can arrive as the connection closing: committed too.
          try {
            await drain();
            await raf?.flush();
            if (streamStarted) await commit(received);
          } catch (_) {}
          if (job.cancelled) {
            return ended(DownloadOutcome.cancelled);
          }
          lastError = e;

          if (isDiskFull(e)) {
            _log('task=$taskId the disk is full at ${_mb(received)}');
            return ended(DownloadOutcome.diskFull, e);
          }
          if (!isTransient(e)) {
            _log('task=$taskId FAILED at ${_mb(received)} err=$e');
            return ended(DownloadOutcome.failed, e);
          }
          // A stretch with no bytes ends after quietAttempts tries; any
          // bytes start a new one.
          quiet = received > attemptStartBytes ? 1 : quiet + 1;
          if (quiet > _quietAttempts) {
            _log(
              'task=$taskId interrupted at ${_mb(received)} after '
              '$_quietAttempts tries with no bytes err=$e',
            );
            return ended(DownloadOutcome.interrupted, e);
          }
          var wait = backoff(
            quiet,
            base: _retryBase,
            cap: _retryCap,
            random: _random,
          );
          final after = e is ServerBusy ? e.after : null;
          if (after != null && after > wait) {
            wait = after > _busyCap ? _busyCap : after;
          }
          _log(
            'task=$taskId trying again in ${wait.inMilliseconds}ms at '
            '${_mb(received)} err=$e',
          );
          try {
            onWaiting?.call(wait, e);
          } catch (e) {
            _log('task=$taskId onWaiting threw: $e');
          }
          await _pause(wait, job);
        }
      }
    } catch (e) {
      if (job.cancelled) {
        return ended(DownloadOutcome.cancelled);
      }
      _log('task=$taskId FAILED (setup) at ${_mb(received)} err=$e');
      return ended(DownloadOutcome.failed, lastError ?? e);
    } finally {
      watchdog?.cancel();
      try {
        await raf?.close();
      } catch (_) {}
      try {
        client?.close();
      } catch (_) {}
      if (identical(_jobs[taskId], job)) _jobs.remove(taskId);
      if (!job.done.isCompleted) job.done.complete();
    }
  }

  /// The complete `.part` takes the file's name. Windows refuses while
  /// another program has it open (an antivirus scan, the search indexer), so
  /// it is tried a few times; a `.part` that still can't is kept, and the
  /// next try finds it complete (416) and tries again.
  Future<DownloadResult> _finish(
    String taskId,
    File part,
    File destination,
    File record,
    int received,
    int total,
  ) async {
    for (var attempt = 1; ; attempt++) {
      try {
        await part.rename(destination.path);
        // The record, and a write of it a crash cut short.
        for (final leftover in [record, File('${record.path}.tmp')]) {
          try {
            await leftover.delete();
          } catch (_) {}
        }
        return DownloadResult(
          DownloadOutcome.completed,
          bytesOnDisk: received,
          totalBytes: total,
        );
      } on FileSystemException catch (e) {
        if (attempt == 3) {
          _log(
            'task=$taskId complete, but the file cannot take its name; '
            'kept as .part: $e',
          );
          return DownloadResult(
            DownloadOutcome.failed,
            bytesOnDisk: received,
            totalBytes: total,
            error: e,
          );
        }
        await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
  }

  /// Waits [wait], or less when the run is cancelled: one timer, ended by
  /// the cancel, never left behind.
  static Future<void> _pause(Duration wait, _Job job) async {
    if (job.cancelled) return;
    final waited = Completer<void>();
    final timer = Timer(wait, waited.complete);
    try {
      await Future.any([waited.future, job.stopped.future]);
    } finally {
      timer.cancel();
    }
  }

  /// Headers the engine sets itself; the caller's are dropped.
  static const _ownedHeaders = {'range', 'if-range', 'accept-encoding'};

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}

class _Job {
  bool cancelled = false;
  http.Client? client;
  final Completer<void> done = Completer<void>();

  /// Completes on [stop]: what the run waits on (a fresh link, a back-off)
  /// stops waiting.
  final Completer<void> stopped = Completer<void>();

  /// Asks the run to stop: its connection closed, its waits ended.
  void stop() {
    cancelled = true;
    if (!stopped.isCompleted) stopped.complete();
    try {
      client?.close();
    } catch (_) {}
  }
}
