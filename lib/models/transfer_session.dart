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
