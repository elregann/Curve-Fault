import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/transfer_manifest.dart';
import '../../models/transfer_session.dart';
import '../../models/vault_entry.dart';
import '../session_service.dart';
import '../vault_crypto.dart';
import '../vault_service.dart';
import 'peer_link.dart';
import 'transfer_auth.dart';
import 'transfer_qr.dart';
import 'transfer_storage.dart';

/// Sends one prepared vault container to a peer over a WebRTC data channel.
///
/// The offer QR only carries connection data. Before a single file byte is
/// sent the sender proves its identity with an XEdDSA signature and asks the
/// receiver for a proof of possession, so a leaked offer cannot be answered by
/// a third party.
class TransferSender extends ChangeNotifier {
  TransferSender({
    required this.entry,
    required this.recipientPublicKeyHex,
    required this.validity,
  });

  final VaultEntry entry;
  final String recipientPublicKeyHex;
  final Duration validity;

  static const int chunkSize = 16 * 1024;
  static const Duration _handshakeTimeout = Duration(seconds: 90);

  TransferPhase _phase = TransferPhase.idle;
  String? _error;
  String? _qrPayload;
  String? _sessionId;
  int _expiresAt = 0;
  int _sentBytes = 0;
  int _totalBytes = 0;
  int _fileSize = 0;
  String? _manifestSignature;
  String? _authSignature;
  String? _ownPublicKeyHex;
  TransferManifest? _manifest;
  PreparedShare? _prepared;
  PeerLink? _link;
  CtrlInbox? _inbox;
  Timer? _expiryTimer;
  bool _disposed = false;
  DateTime _lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);

  TransferPhase get phase => _phase;
  String? get errorMessage => _error;
  String? get qrPayload => _qrPayload;
  String? get sessionId => _sessionId;
  int get expiresAt => _expiresAt;
  int get sentBytes => _sentBytes;
  int get totalBytes => _totalBytes;
  int get fileSize => _fileSize;
  String get fileName => entry.name;
  bool get isActive =>
      _phase == TransferPhase.preparing ||
      _phase == TransferPhase.waitingAnswer ||
      _phase == TransferPhase.connecting ||
      _phase == TransferPhase.transferring;

  Future<void> start() async {
    if (_phase != TransferPhase.idle) return;
    _setPhase(TransferPhase.preparing);
    try {
      final seed = SessionService.masterSeed;
      final ownKey = SessionService.publicKeyHex;
      if (seed == null || ownKey == null) {
        throw const TransferException('Unlock the vault to start a transfer');
      }
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(recipientPublicKeyHex)) {
        throw const TransferException('Enter a valid Curve256189 public key');
      }
      if (recipientPublicKeyHex == ownKey) {
        throw const TransferException('That is your own public key');
      }
      if (validity <= Duration.zero) {
        throw const TransferException('Choose how long the QR stays valid');
      }

      _ownPublicKeyHex = ownKey;
      _sessionId = TransferAuth.hexOf(VaultCrypto.randomBytes(16));
      final outgoingPath = await TransferStorage.instance.newOutgoingPath();
      _prepared = await VaultService.instance.prepareSharedContainer(
        entry,
        TransferAuth.publicKeyBytes(recipientPublicKeyHex)!,
        outputPath: outgoingPath,
      );
      _fileSize = _prepared!.size;
      _totalBytes = await _prepared!.container.length();
      if (_totalBytes <= 0) {
        throw const TransferException('The encrypted file is empty');
      }

      final hash = await TransferStorage.instance.hashFileHex(
        _prepared!.container,
      );
      final manifest = TransferManifest(
        sessionId: _sessionId!,
        name: _prepared!.name,
        mime: _prepared!.mime,
        size: _prepared!.size,
        containerSize: _totalBytes,
        sha256: hash,
        senderPublicKey: ownKey,
        recipientPublicKey: recipientPublicKeyHex,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      _manifest = manifest;
      _manifestSignature = await TransferAuth.signManifest(
        manifest: manifest,
        seed: seed,
      );
      _authSignature = await TransferAuth.signAuth(
        seed: seed,
        sessionId: _sessionId!,
        senderPublicKey: ownKey,
        recipientPublicKey: recipientPublicKeyHex,
      );

      final link = await PeerLink.sender();
      _link = link;
      _inbox = CtrlInbox(link.ctrlMessages);
      final offerSdp = await link.createOffer();

      _expiresAt = DateTime.now()
          .add(validity)
          .millisecondsSinceEpoch ~/
          1000;
      _qrPayload = TransferQrPayload(
        role: TransferQrRole.offer,
        sessionId: _sessionId!,
        fromPublicKey: ownKey,
        expiresAt: _expiresAt,
        sdp: offerSdp,
      ).encode();

      _setPhase(TransferPhase.waitingAnswer);
      _startExpiryTimer();
    } catch (error) {
      await _fail(error);
    }
  }

  /// Applies the receiver's answer QR and runs the rest of the transfer.
  Future<void> acceptAnswer(String rawQr) async {
    if (_phase != TransferPhase.waitingAnswer) {
      throw const TransferException('This session is not waiting for an answer');
    }
    final link = _link;
    final inbox = _inbox;
    final sessionId = _sessionId;
    // Captured while the vault was unlocked so answering the QR still works
    // after the app has locked and cleared the session seed.
    final ownKey = _ownPublicKeyHex;
    if (link == null ||
        inbox == null ||
        sessionId == null ||
        ownKey == null ||
        _manifest == null ||
        _manifestSignature == null ||
        _authSignature == null) {
      throw const TransferException('This session is not ready');
    }

    try {
      final payload = TransferQrPayload.decode(rawQr);
      if (payload.role != TransferQrRole.answer) {
        throw const TransferException('That is not an answer QR code');
      }
      if (payload.sessionId != sessionId) {
        throw const TransferException('That answer belongs to another session');
      }
      if (payload.fromPublicKey != recipientPublicKeyHex) {
        throw const TransferException(
          'That answer was not created by the chosen identity',
        );
      }
      if (payload.isExpired()) {
        await _expire();
        throw const TransferException('This session has expired');
      }

      _setPhase(TransferPhase.connecting);
      await link.applyAnswer(payload.sdp);
      await link.waitForChannels(timeout: const Duration(minutes: 2));

      await link.sendCtrl(<String, dynamic>{
        't': 'auth',
        'sid': sessionId,
        'sig': _authSignature,
      });

      final pop = await inbox.next('pop', timeout: _handshakeTimeout);
      if (pop['sid'] != sessionId) {
        throw const TransferException('The other device sent a bad response');
      }
      final popSignature = pop['sig'];
      if (popSignature is! String ||
          !await TransferAuth.verifyProofOfPossession(
            signature: popSignature,
            sessionId: sessionId,
            recipientPublicKey: recipientPublicKeyHex,
            senderPublicKey: ownKey,
          )) {
        throw const TransferException(
          'The other device could not prove the identity',
        );
      }

      await link.sendCtrl(<String, dynamic>{
        't': 'manifest',
        'sid': sessionId,
        'manifest': _manifest!.toJson(),
        'sig': _manifestSignature,
      });
      final accept = await inbox.next('accept', timeout: _handshakeTimeout);
      if (accept['sid'] != sessionId) {
        throw const TransferException('The other device rejected the file');
      }

      _expiryTimer?.cancel();
      _setPhase(TransferPhase.transferring);
      await _sendFile(link, sessionId);

      final received = await inbox.next('received');
      if (received['sid'] != sessionId) {
        throw const TransferException('The other device rejected the file');
      }
      _setPhase(TransferPhase.completed);
      await _cleanupOutgoing();
    } catch (error) {
      await _fail(error);
      rethrow;
    }
  }

  Future<void> _sendFile(PeerLink link, String sessionId) async {
    final prepared = _prepared;
    if (prepared == null) {
      throw const TransferException('The encrypted file is missing');
    }

    final reader = await prepared.container.open(mode: FileMode.read);
    final buffer = Uint8List(chunkSize);
    var sent = 0;
    try {
      while (true) {
        final read = await reader.readInto(buffer);
        if (read <= 0) break;
        final chunk = Uint8List.fromList(buffer.sublist(0, read));
        await link.sendData(chunk);
        sent += read;
        _sentBytes = sent;
        _notifyProgress();
        if (_phase == TransferPhase.cancelled) {
          throw const TransferException('Transfer cancelled');
        }
      }
    } finally {
      await reader.close();
    }

    if (sent != _totalBytes) {
      throw const TransferException('The encrypted file changed while sending');
    }
    await link.sendCtrl(<String, dynamic>{
      't': 'complete',
      'sid': sessionId,
      'bytes': sent,
    });
  }

  Future<void> cancel() async {
    if (_phase == TransferPhase.completed ||
        _phase == TransferPhase.cancelled ||
        _phase == TransferPhase.failed) {
      return;
    }
    _expiryTimer?.cancel();
    _inbox?.failAll(const TransferException('Transfer cancelled'));
    await _link?.close();
    _setPhase(TransferPhase.cancelled);
    await _cleanupOutgoing();
  }

  Future<void> _expire() async {
    _expiryTimer?.cancel();
    _inbox?.failAll(const TransferException('This session has expired'));
    await _link?.close();
    _error = null;
    _setPhase(TransferPhase.expired);
    await _cleanupOutgoing();
  }

  Future<void> _fail(Object error) async {
    if (_disposed) return;
    _expiryTimer?.cancel();
    _inbox?.failAll(error);
    await _link?.close();
    if (_phase != TransferPhase.expired &&
        _phase != TransferPhase.cancelled &&
        _phase != TransferPhase.completed) {
      _error = _messageFor(error);
      _setPhase(TransferPhase.failed);
    }
    await _cleanupOutgoing();
  }

  Future<void> _cleanupOutgoing() async {
    final prepared = _prepared;
    if (prepared == null) return;
    try {
      if (prepared.container.existsSync()) {
        await prepared.container.delete();
      }
    } catch (_) {
      // The app cleans the outgoing directory on the next launch.
    }
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
      if (_phase == TransferPhase.waitingAnswer ||
          _phase == TransferPhase.connecting) {
        unawaited(_expire());
      }
    });
  }

  void _notifyProgress() {
    final now = DateTime.now();
    if (now.difference(_lastProgressNotify) <
        const Duration(milliseconds: 120)) {
      return;
    }
    _lastProgressNotify = now;
    notifyListeners();
  }

  void _setPhase(TransferPhase phase) {
    if (_disposed) return;
    _phase = phase;
    notifyListeners();
  }

  static String _messageFor(Object error) {
    if (error is TransferException) return error.message;
    if (error is TransferQrException) return 'The QR code could not be read';
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  @override
  void dispose() {
    _disposed = true;
    _expiryTimer?.cancel();
    unawaited(_inbox?.dispose() ?? Future<void>.value());
    unawaited(_link?.close() ?? Future<void>.value());
    unawaited(_cleanupOutgoing());
    super.dispose();
  }
}
