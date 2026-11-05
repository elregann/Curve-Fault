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

/// A user-facing transfer failure with a safe message.
class TransferException implements Exception {
  const TransferException(this.message);

  final String message;

  @override
  String toString() => message;
}
