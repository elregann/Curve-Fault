import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/transfer_manifest.dart';
import '../../models/transfer_session.dart';
import '../session_service.dart';
import '../vault_service.dart';
import 'peer_link.dart';
import 'transfer_auth.dart';
import 'transfer_qr.dart';
import 'transfer_storage.dart';

/// Receives one encrypted vault container from a sender's QR offer.
///
/// The answer QR (and the proof of possession inside it) is created while the
/// vault is still unlocked. From then on the transfer itself needs no vault
/// key: the received container and its signed sidecar are written to
/// app-private storage, and the vault imports them on this or the next unlock.
class TransferReceiver extends ChangeNotifier {
  TransferReceiver({required this.offerQr});

  final String offerQr;

  static const Duration _handshakeTimeout = Duration(seconds: 90);

  TransferPhase _phase = TransferPhase.idle;
  String? _error;
  String? _qrPayload;
  String? _sessionId;
  String? _senderPublicKeyHex;
  String? _ownPublicKeyHex;
  String? _popSignature;
  int _expiresAt = 0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  int _fileSize = 0;
  String? _fileName;
  File? _incoming;
  RandomAccessFile? _reader;
  PeerLink? _link;
  CtrlInbox? _inbox;
  StreamSubscription<Uint8List>? _dataSubscription;
  final Completer<void> _bytesDone = Completer<void>();
  Future<void> _writeChain = Future<void>.value();
  Timer? _expiryTimer;
  bool _disposed = false;
  bool _aborted = false;

  TransferPhase get phase => _phase;
  String? get errorMessage => _error;
  String? get qrPayload => _qrPayload;
  String? get sessionId => _sessionId;
  String? get senderPublicKeyHex => _senderPublicKeyHex;
  int get expiresAt => _expiresAt;
  int get receivedBytes => _receivedBytes;
  int get totalBytes => _totalBytes;
  int get fileSize => _fileSize;
  String? get fileName => _fileName;
  bool get isActive =>
      _phase == TransferPhase.preparing ||
      _phase == TransferPhase.waitingConnection ||
      _phase == TransferPhase.connecting ||
      _phase == TransferPhase.transferring;

  Future<void> start() async {
    if (_phase != TransferPhase.idle) return;
    _setPhase(TransferPhase.preparing);
    try {
      final seed = SessionService.masterSeed;
      final ownKey = SessionService.publicKeyHex;
      if (seed == null || ownKey == null) {
        throw const TransferException('Unlock the vault to receive a file');
      }

      final offer = TransferQrPayload.decode(offerQr);
      if (offer.role != TransferQrRole.offer) {
        throw const TransferException('That is not an offer QR code');
      }
      if (offer.isExpired()) {
        _error = 'QR is no longer valid';
        _setPhase(TransferPhase.expired);
        return;
      }

      _sessionId = offer.sessionId;
      _senderPublicKeyHex = offer.fromPublicKey;
      _ownPublicKeyHex = ownKey;
      _expiresAt = offer.expiresAt;
      _popSignature = await TransferAuth.signProofOfPossession(
        seed: seed,
        sessionId: offer.sessionId,
        recipientPublicKey: ownKey,
        senderPublicKey: offer.fromPublicKey,
      );

      final link = await PeerLink.receiver();
      _link = link;
      _inbox = CtrlInbox(link.ctrlMessages);
      final answerSdp = await link.createAnswer(offer.sdp);
      _qrPayload = TransferQrPayload(
        role: TransferQrRole.answer,
        sessionId: offer.sessionId,
        fromPublicKey: ownKey,
        expiresAt: offer.expiresAt,
        sdp: answerSdp,
      ).encode();

      _setPhase(TransferPhase.waitingConnection);
      _startExpiryTimer();
      unawaited(_run());
    } catch (error) {
      await _fail(error);
    }
  }

  Future<void> _run() async {
    final link = _link;
    final inbox = _inbox;
    final sessionId = _sessionId;
    final senderKey = _senderPublicKeyHex;
    final ownKey = _ownPublicKeyHex;
    if (link == null ||
        inbox == null ||
        sessionId == null ||
        senderKey == null ||
        ownKey == null) {
      return;
    }

    try {
      // Wait for the sender until the QR itself expires, rather than the
      // default connection window: showing the answer to a friend can take a
      // while and the QR validity is the only user-visible limit.
      final remainingSeconds =
          _expiresAt - DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final window = Duration(
        seconds: remainingSeconds.clamp(30, 35 * 60).toInt() + 30,
      );
      await link.waitForChannels(timeout: window);
      if (_phase == TransferPhase.expired) return;
      _setPhase(TransferPhase.connecting);

      final auth = await inbox.next('auth', timeout: _handshakeTimeout);
      if (auth['sid'] != sessionId) {
        throw const TransferException('The sender used a different session');
      }
      final authSignature = auth['sig'];
      if (authSignature is! String ||
          !await TransferAuth.verifyAuth(
            signature: authSignature,
            sessionId: sessionId,
            senderPublicKey: senderKey,
            recipientPublicKey: ownKey,
          )) {
        throw const TransferException('The sender could not prove the identity');
      }

      final popSignature = _popSignature;
      if (popSignature == null) {
        throw const TransferException('This session is not ready');
      }
      await link.sendCtrl(<String, dynamic>{
        't': 'pop',
        'sid': sessionId,
        'sig': popSignature,
      });

      final manifestMessage = await inbox.next(
        'manifest',
        timeout: _handshakeTimeout,
      );
      if (manifestMessage['sid'] != sessionId) {
        throw const TransferException('The sender used a different session');
      }
      final rawManifest = manifestMessage['manifest'];
      if (rawManifest is! Map) {
        throw const TransferException('The sender sent an invalid file');
      }
      final manifest = TransferManifest.fromJson(
        Map<String, dynamic>.from(rawManifest),
      );
      final manifestSignature = manifestMessage['sig'];
      if (manifestSignature is! String) {
        throw const TransferException('The sender sent an invalid file');
      }
      if (manifest.sessionId != sessionId ||
          manifest.senderPublicKey != senderKey ||
          manifest.recipientPublicKey != ownKey) {
        throw const TransferException('The sender sent a file for someone else');
      }
      if (manifest.containerSize <= 0) {
        throw const TransferException('The sender sent an empty file');
      }
      if (!await TransferAuth.verifyManifest(
        manifest: manifest,
        signature: manifestSignature,
      )) {
        throw const TransferException('The sender signature is not valid');
      }

      _fileName = manifest.name;
      _fileSize = manifest.size;
      _totalBytes = manifest.containerSize;
      _receivedBytes = 0;
      _incoming = await TransferStorage.instance.newIncomingTemp();
      _reader = await _incoming!.open(mode: FileMode.write);
      _dataSubscription = link.dataMessages.listen(_onData);

      await link.sendCtrl(<String, dynamic>{'t': 'accept', 'sid': sessionId});
      _expiryTimer?.cancel();
      _setPhase(TransferPhase.transferring);

      final complete = await inbox.next('complete');
      if (complete['sid'] != sessionId) {
        throw const TransferException('The sender used a different session');
      }
      final declaredBytes = complete['bytes'];
      if (declaredBytes is num && declaredBytes.toInt() != _totalBytes) {
        throw const TransferException('The sender sent an incomplete file');
      }

      await _bytesDone.future;
      await _writeChain;
      if (_phase != TransferPhase.transferring) return;
      final file = _reader;
      _reader = null;
      if (file != null) {
        await file.flush();
        await file.close();
      }
      if (_aborted) return;
      if (_receivedBytes != _totalBytes) {
        throw const TransferException('The file transfer did not finish');
      }

      final incoming = _incoming;
      if (incoming == null) {
        throw const TransferException('The received file is missing');
      }
      final hash = await TransferStorage.instance.hashFileHex(incoming);
      if (!TransferAuth.constantTimeEqualsHex(hash, manifest.sha256)) {
        throw const TransferException('The received file failed verification');
      }

      final receivedAt = DateTime.now().millisecondsSinceEpoch;
      await TransferStorage.instance.writeSidecar(
        container: incoming,
        manifest: manifest,
        signature: manifestSignature,
        receivedAt: receivedAt,
      );
      await TransferStorage.instance.commitReceived(
        temporary: incoming,
        manifest: manifest,
      );
      _incoming = null;

      // Import is best-effort here: the container and its signed sidecar are
      // already committed, so the next unlock can index it if this fails.
      try {
        await VaultService.instance.importPendingReceived();
      } catch (_) {
        // The next unlock retries.
      }
      try {
        await link.sendCtrl(<String, dynamic>{'t': 'received', 'sid': sessionId});
      } catch (_) {
        // The container and sidecar are already committed, so a lost
        // acknowledgement must not turn a successful receive into a failure.
      }
      _setPhase(TransferPhase.completed);
    } catch (error) {
      await _fail(error);
    } finally {
      await _dataSubscription?.cancel();
      _dataSubscription = null;
    }
  }

  void _onData(Uint8List chunk) {
    if (_aborted || _phase != TransferPhase.transferring) return;
    if (_receivedBytes + chunk.length > _totalBytes) {
      _abort(const TransferException('The sender sent too much data'));
      return;
    }
    _receivedBytes += chunk.length;
    _writeChain = _writeChain.then((_) async {
      try {
        await _reader?.writeFrom(chunk);
      } catch (error) {
        _abort(error);
      }
    });
    if (_receivedBytes == _totalBytes && !_bytesDone.isCompleted) {
      _bytesDone.complete();
    }
  }

  void _abort(Object error) {
    if (_aborted) return;
    _aborted = true;
    unawaited(_fail(error));
  }

  void _startExpiryTimer() {
    _expiryTimer?.cancel();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final seconds = _expiresAt - now;
    if (seconds <= 0) {
      unawaited(_expire());
      return;
    }
    _expiryTimer = Timer(Duration(seconds: seconds), () {
      if (_phase == TransferPhase.waitingConnection ||
          _phase == TransferPhase.connecting) {
        unawaited(_expire());
      }
    });
  }

  Future<void> _expire() async {
    _expiryTimer?.cancel();
    _inbox?.failAll(const TransferException('QR is no longer valid'));
    await _link?.close();
    if (!_bytesDone.isCompleted) _bytesDone.complete();
    _error = 'QR is no longer valid';
    _setPhase(TransferPhase.expired);
    await _cleanupIncoming();
  }

  Future<void> cancel() async {
    if (_phase == TransferPhase.completed || _phase == TransferPhase.cancelled) {
      return;
    }
    _expiryTimer?.cancel();
    _inbox?.failAll(const TransferException('Transfer cancelled'));
    await _link?.close();
    if (!_bytesDone.isCompleted) _bytesDone.complete();
    _setPhase(TransferPhase.cancelled);
    await _cleanupIncoming();
  }

  Future<void> _fail(Object error) async {
    if (_disposed) return;
    _expiryTimer?.cancel();
    _inbox?.failAll(error);
    await _link?.close();
    if (!_bytesDone.isCompleted) _bytesDone.complete();
    if (_phase != TransferPhase.expired &&
        _phase != TransferPhase.cancelled &&
        _phase != TransferPhase.completed) {
      _error = _messageFor(error);
      _setPhase(TransferPhase.failed);
    }
    await _cleanupIncoming();
  }

  Future<void> _cleanupIncoming() async {
    try {
      await _reader?.close();
    } catch (_) {
      // Already closed.
    }
    _reader = null;
    final incoming = _incoming;
    if (incoming == null) return;
    _incoming = null;
    try {
      if (incoming.existsSync()) {
        await incoming.delete();
      }
      final sidecar = TransferStorage.instance.sidecarFor(incoming);
      if (sidecar.existsSync()) {
        await sidecar.delete();
      }
    } catch (_) {
      // The app cleans the temporary directory on the next launch.
    }
  }

  void _setPhase(TransferPhase phase) {
    if (_disposed) return;
    _phase = phase;
    notifyListeners();
  }

  static String _messageFor(Object error) {
    if (error is TransferException) return error.message;
    if (error is TransferQrException) return 'The QR code could not be read';
    if (error is FormatException) return 'The sender sent an invalid file';
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  @override
  void dispose() {
    _disposed = true;
    _expiryTimer?.cancel();
    unawaited(_dataSubscription?.cancel() ?? Future<void>.value());
    unawaited(_inbox?.dispose() ?? Future<void>.value());
    unawaited(_link?.close() ?? Future<void>.value());
    unawaited(_cleanupIncoming());
    if (!_bytesDone.isCompleted) {
      _bytesDone.complete();
    }
    super.dispose();
  }
}
