import 'package:curve_fault/models/transfer_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('expiring while waiting gives a notice for the sender', () {
    final notice = TransferNotice.forChange(
      TransferPhase.waitingAnswer,
      TransferPhase.expired,
      isSender: true,
    );

    expect(notice, isNotNull);
    expect(notice, contains('expired'));
  });

  test('expiring gives a notice for the receiver too', () {
    final notice = TransferNotice.forChange(
      TransferPhase.waitingConnection,
      TransferPhase.expired,
      isSender: false,
    );

    expect(notice, isNotNull);
    expect(notice, contains('expired'));
  });

  test('an expired session does not announce itself twice', () {
    expect(
      TransferNotice.forChange(
        TransferPhase.expired,
        TransferPhase.expired,
        isSender: true,
      ),
      isNull,
    );
  });

  test('other phase changes stay silent', () {
    for (final next in TransferPhase.values) {
      if (next == TransferPhase.expired) continue;
      expect(
        TransferNotice.forChange(
          TransferPhase.waitingAnswer,
          next,
          isSender: true,
        ),
        isNull,
        reason: '$next',
      );
    }
  });

  test('a new session replacing an expired one stays silent', () {
    expect(
      TransferNotice.forChange(
        TransferPhase.expired,
        TransferPhase.idle,
        isSender: true,
      ),
      isNull,
    );
  });
}
