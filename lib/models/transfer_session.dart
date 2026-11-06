/// Which side of a transfer a QR payload belongs to.
enum TransferQrRole { offer, answer }

/// Lifecycle shared by the sender and receiver screens.
enum TransferPhase {
  idle,
  preparing,

  /// Sender is showing the offer QR and waiting for the answer QR.
  waitingAnswer,

  /// Receiver is showing the answer QR and waiting for the connection.
  waitingConnection,

  connecting,
  transferring,
  completed,
  expired,
  failed,
  cancelled,
}

enum TransferNotificationMode { waiting, connecting, transferring }

/// What the Android foreground notification should say for a transfer state.
/// It never carries the file name, since notifications can be seen while the
/// phone is locked.
class TransferNotificationSpec {
  const TransferNotificationSpec({
    required this.mode,
    required this.title,
    required this.text,
    this.progress,
  });

  final TransferNotificationMode mode;
  final String title;
  final String text;

  /// Whole percent, only while transferring.
  final int? progress;

  static const _transferringText =
      'End-to-end encrypted. Nothing is stored online.';

  static TransferNotificationSpec? forState(
    TransferPhase phase, {
    required bool isSender,
    double? progress,
  }) {
    switch (phase) {
      case TransferPhase.preparing:
        return const TransferNotificationSpec(
          mode: TransferNotificationMode.waiting,
          title: 'Getting the transfer ready',
          text: 'This only takes a moment.',
        );
      case TransferPhase.waitingAnswer:
      case TransferPhase.waitingConnection:
        return const TransferNotificationSpec(
          mode: TransferNotificationMode.waiting,
          title: 'Waiting for the other device',
          text: 'You can switch apps while this runs.',
        );
      case TransferPhase.connecting:
        return const TransferNotificationSpec(
          mode: TransferNotificationMode.connecting,
          title: 'Connecting to the other device',
          text: 'Setting up an encrypted link.',
        );
      case TransferPhase.transferring:
        return TransferNotificationSpec(
          mode: TransferNotificationMode.transferring,
          title: isSender ? 'Sending a secret file' : 'Receiving a secret file',
          text: _transferringText,
          progress: ((progress ?? 0) * 100).floor().clamp(0, 100),
        );
      case TransferPhase.idle:
      case TransferPhase.completed:
      case TransferPhase.expired:
      case TransferPhase.failed:
      case TransferPhase.cancelled:
        return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is TransferNotificationSpec &&
      other.mode == mode &&
      other.title == title &&
      other.text == text &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(mode, title, text, progress);
}

/// Short messages shown when a transfer changes phase on its own.
class TransferNotice {
  TransferNotice._();

  static String? forChange(
    TransferPhase previous,
    TransferPhase next, {
    required bool isSender,
  }) {
    if (next != TransferPhase.expired || previous == TransferPhase.expired) {
      return null;
    }
    return isSender
        ? 'The QR expired before the other device answered. '
              'Start a new transfer to try again.'
        : 'The QR expired before the sender connected. '
              'Ask them to start a new transfer.';
  }
}

/// A user-facing transfer failure with a safe message.
class TransferException implements Exception {
  const TransferException(this.message);

  final String message;

  @override
  String toString() => message;
}
