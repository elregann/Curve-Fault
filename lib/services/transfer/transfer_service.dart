import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../models/transfer_session.dart';
import '../../models/vault_entry.dart';
import '../native_storage.dart';
import 'transfer_receiver.dart';
import 'transfer_sender.dart';
import 'transfer_storage.dart';

/// Owns the one active peer transfer and keeps it alive across app locks.
///
/// The vault locks after a minute away from the app, and sharing a QR usually
/// means leaving for WhatsApp. The transfer object therefore lives here rather
/// than in a page, and an Android foreground service plus a wakelock keep the
/// WebRTC process running while the user is elsewhere.
class TransferService extends ChangeNotifier {
  TransferService._();

  static final TransferService instance = TransferService._();

  TransferSender? _sender;
  TransferReceiver? _receiver;
  VoidCallback? _attachedListener;
  ChangeNotifier? _attached;
  bool _nativeRunning = false;
  TransferNotificationSpec? _lastSpec;

  TransferSender? get sender => _sender;
  TransferReceiver? get receiver => _receiver;
  bool get hasActive => _sender?.isActive == true || _receiver?.isActive == true;
  bool get isSender => _sender != null;

  TransferPhase get phase =>
      _sender?.phase ?? _receiver?.phase ?? TransferPhase.idle;

  String? get errorMessage => _sender?.errorMessage ?? _receiver?.errorMessage;

  String? get fileName => _sender?.fileName ?? _receiver?.fileName;

  int get fileSize => _sender?.fileSize ?? _receiver?.fileSize ?? 0;

  double? get progress {
    final sender = _sender;
    if (sender != null && sender.totalBytes > 0) {
      return (sender.sentBytes / sender.totalBytes).clamp(0.0, 1.0);
    }
    final receiver = _receiver;
    if (receiver != null && receiver.totalBytes > 0) {
      return (receiver.receivedBytes / receiver.totalBytes).clamp(0.0, 1.0);
    }
    return null;
  }

  Future<void> startSending({
    required VaultEntry entry,
    required String recipientPublicKeyHex,
    required Duration validity,
  }) async {
    await _reset();
    final sender = TransferSender(
      entry: entry,
      recipientPublicKeyHex: recipientPublicKeyHex.toLowerCase(),
      validity: validity,
    );
    _sender = sender;
    _attach(sender);
    await sender.start();
    if (sender.phase != TransferPhase.waitingAnswer) {
      throw TransferException(sender.errorMessage ?? 'Could not start the transfer');
    }
    await _beginSession();
  }

  Future<void> startReceiving({required String offerQr}) async {
    await _reset();
    final receiver = TransferReceiver(offerQr: offerQr);
    _receiver = receiver;
    _attach(receiver);
    await receiver.start();
    if (receiver.phase != TransferPhase.waitingConnection &&
        receiver.phase != TransferPhase.expired) {
      throw TransferException(
        receiver.errorMessage ?? 'Could not read the offer',
      );
    }
    if (receiver.phase == TransferPhase.waitingConnection) {
      await _beginSession();
    } else {
      notifyListeners();
    }
  }

  Future<void> acceptAnswer(String answerQr) async {
    final sender = _sender;
    if (sender == null) {
      throw const TransferException('No outgoing transfer is waiting');
    }
    await sender.acceptAnswer(answerQr);
  }

  /// Expires a waiting session whose QR validity has passed.
  Future<void> checkExpiry() async {
    await _sender?.expireIfDue();
    await _receiver?.expireIfDue();
  }

  Future<void> cancel() async {
    final sender = _sender;
    final receiver = _receiver;
    if (sender != null) await sender.cancel();
    if (receiver != null) await receiver.cancel();
    await _stopNativeSession();
    notifyListeners();
  }

  /// Clears finished or abandoned leftovers without touching a live transfer.
  Future<void> cleanupAtStartup() async {
    if (hasActive) return;
    try {
      await TransferStorage.instance.cleanupTemporary();
      await TransferStorage.instance.cleanupOutgoing();
    } catch (_) {
      // Startup cleanup is best-effort.
    }
  }

  void _attach(ChangeNotifier flow) {
    _attached = flow;
    _attachedListener = _onFlowChanged;
    flow.addListener(_attachedListener!);
  }

  void _onFlowChanged() {
    final active = hasActive;
    if (!active && _nativeRunning) {
      _stopNativeSoon();
    }
    _pushNotification();
    notifyListeners();
  }

  TransferNotificationSpec? _currentSpec() {
    return TransferNotificationSpec.forState(
      phase,
      isSender: isSender,
      progress: progress,
    );
  }

  /// Sends the notification wording only when it actually changed. Progress
  /// is whole percents, so a transfer sends at most about a hundred updates.
  void _pushNotification() {
    if (!_nativeRunning) return;
    final spec = _currentSpec();
    if (spec == null || spec == _lastSpec) return;
    _lastSpec = spec;
    unawaited(
      NativeStorage.updateTransferNotification(
        mode: spec.mode.name,
        title: spec.title,
        text: spec.text,
        progress: spec.progress,
      ).then((sent) {
        // Only remember the state that reached the service, so a failed
        // update is retried on the next flow change.
        if (!sent && _lastSpec == spec) {
          _lastSpec = null;
        }
      }),
    );
  }

  void _stopNativeSoon() {
    _nativeRunning = false;
    _lastSpec = null;
    unawaited(NativeStorage.stopTransferService());
    unawaited(WakelockPlus.disable().catchError((Object _) {}));
  }

  Future<void> _beginSession() async {
    if (!_nativeRunning) {
      _nativeRunning = true;
      final spec = _currentSpec();
      _lastSpec = spec;
      final started = await NativeStorage.startTransferService(
        mode: spec?.mode.name,
        title: spec?.title,
        text: spec?.text,
        progress: spec?.progress,
      );
      if (!started) {
        _nativeRunning = false;
        _lastSpec = null;
      } else if (_nativeRunning) {
        // The phase can move while the service warms up. Re-send the current
        // state once it exists so the notification never stays on the first one.
        _lastSpec = null;
        _pushNotification();
      }
      try {
        await WakelockPlus.enable();
      } catch (_) {
        // The foreground service is the primary guard.
      }
      await _requestNotificationPermission();
    }
    notifyListeners();
  }

  Future<void> _requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.notification.status;
      if (status.isDenied) {
        await Permission.notification.request();
      }
    } catch (_) {
      // A denied notification only hides the service notification.
    }
  }

  Future<void> _stopNativeSession() async {
    if (!_nativeRunning) return;
    _nativeRunning = false;
    _lastSpec = null;
    await NativeStorage.stopTransferService();
    try {
      await WakelockPlus.disable();
    } catch (_) {
      // Best-effort.
    }
  }

  Future<void> _reset() async {
    await cancel();
    final attached = _attached;
    final listener = _attachedListener;
    if (attached != null && listener != null) {
      attached.removeListener(listener);
    }
    _attached = null;
    _attachedListener = null;
    _sender?.dispose();
    _receiver?.dispose();
    _sender = null;
    _receiver = null;
  }

  String get activeLabel {
    switch (phase) {
      case TransferPhase.preparing:
        return 'Preparing the encrypted copy…';
      case TransferPhase.waitingAnswer:
        return 'Waiting for the answer QR';
      case TransferPhase.waitingConnection:
        return 'Waiting for the sender to connect';
      case TransferPhase.connecting:
        return 'Connecting to the other device…';
      case TransferPhase.transferring:
        return isSender ? 'Sending $fileName' : 'Receiving $fileName';
      case TransferPhase.completed:
        return isSender ? 'File sent' : 'File received';
      case TransferPhase.expired:
        return 'Session expired';
      case TransferPhase.failed:
        return errorMessage ?? 'Transfer failed';
      case TransferPhase.cancelled:
        return 'Transfer cancelled';
      case TransferPhase.idle:
        return 'No active transfer';
    }
  }
}
