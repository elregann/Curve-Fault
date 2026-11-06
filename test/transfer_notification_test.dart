import 'package:curve_fault/models/transfer_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const privacyText = 'End-to-end encrypted. Nothing is stored online.';

  TransferNotificationSpec? spec(
    TransferPhase phase, {
    bool sender = true,
    double? progress,
  }) {
    return TransferNotificationSpec.forState(
      phase,
      isSender: sender,
      progress: progress,
    );
  }

  test('waiting phases use the background-friendly waiting notification', () {
    final sender = spec(TransferPhase.waitingAnswer)!;
    final receiver = spec(
      TransferPhase.waitingConnection,
      sender: false,
    )!;

    for (final waiting in [sender, receiver]) {
      expect(waiting.mode, TransferNotificationMode.waiting);
      expect(waiting.title, 'Waiting for the other device');
      expect(waiting.text, contains('switch apps'));
      expect(waiting.progress, isNull);
    }
  });

  test('preparing stays in the waiting mode with its own text', () {
    final preparing = spec(TransferPhase.preparing)!;

    expect(preparing.mode, TransferNotificationMode.waiting);
    expect(preparing.title, 'Getting the transfer ready');
    expect(preparing.progress, isNull);
  });

  test('connecting is its own mode and promises an encrypted link', () {
    final connecting = spec(TransferPhase.connecting)!;

    expect(connecting.mode, TransferNotificationMode.connecting);
    expect(connecting.title, 'Connecting to the other device');
    expect(connecting.text, contains('encrypted link'));
    expect(connecting.progress, isNull);
  });

  test('the sender sees the privacy message while sending', () {
    final sending = spec(TransferPhase.transferring, progress: 0.42)!;

    expect(sending.mode, TransferNotificationMode.transferring);
    expect(sending.title, 'Sending a secret file');
    expect(sending.text, privacyText);
    expect(sending.progress, 42);
  });

  test('the receiver sees the privacy message while receiving', () {
    final receiving = spec(
      TransferPhase.transferring,
      sender: false,
      progress: 0.5,
    )!;

    expect(receiving.title, 'Receiving a secret file');
    expect(receiving.text, privacyText);
    expect(receiving.progress, 50);
  });

  test('progress is floored, clamped and defaults to zero', () {
    expect(spec(TransferPhase.transferring, progress: 0.999)!.progress, 99);
    expect(spec(TransferPhase.transferring, progress: 1.7)!.progress, 100);
    expect(spec(TransferPhase.transferring, progress: -0.2)!.progress, 0);
    expect(spec(TransferPhase.transferring)!.progress, 0);
  });

  test('finished phases have no notification', () {
    for (final phase in [
      TransferPhase.idle,
      TransferPhase.completed,
      TransferPhase.expired,
      TransferPhase.failed,
      TransferPhase.cancelled,
    ]) {
      expect(spec(phase), isNull, reason: '$phase');
    }
  });

  test('no copy asks the user to stay in the app', () {
    for (final phase in TransferPhase.values) {
      for (final sender in [true, false]) {
        final value = spec(phase, sender: sender);
        if (value == null) continue;
        final copy = '${value.title} ${value.text}'.toLowerCase();
        expect(copy, isNot(contains('keep the app open')), reason: '$phase');
      }
    }
  });

  test('equal states compare equal so unchanged ones can be skipped', () {
    expect(
      spec(TransferPhase.transferring, progress: 0.421),
      spec(TransferPhase.transferring, progress: 0.425),
    );
    expect(
      spec(TransferPhase.transferring, progress: 0.42),
      isNot(spec(TransferPhase.transferring, progress: 0.43)),
    );
    expect(
      spec(TransferPhase.transferring),
      isNot(spec(TransferPhase.transferring, sender: false)),
    );
  });
}
