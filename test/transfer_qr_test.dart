import 'dart:convert';
import 'dart:io';

import 'package:curve_fault/models/transfer_session.dart';
import 'package:curve_fault/services/transfer/transfer_qr.dart';
import 'package:flutter_test/flutter_test.dart';

const _sessionId = '00112233445566778899aabbccddeeff';
const _publicKey =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _otherKey =
    'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

const _sdp = 'v=0\r\n'
    'o=- 1 1 IN IP4 127.0.0.1\r\n'
    's=-\r\n'
    't=0 0\r\n'
    'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n'
    'c=IN IP4 0.0.0.0\r\n'
    'a=ice-ufrag:abcd\r\n'
    'a=ice-pwd:abcdefghijklmnopqrstuvwx\r\n';

TransferQrPayload _payload({
  TransferQrRole role = TransferQrRole.offer,
  String sessionId = _sessionId,
  String from = _publicKey,
  int expiresAt = 4102444800,
  String sdp = _sdp,
}) {
  return TransferQrPayload(
    role: role,
    sessionId: sessionId,
    fromPublicKey: from,
    expiresAt: expiresAt,
    sdp: sdp,
  );
}

String _encodeRaw(Map<String, dynamic> json) {
  final compressed = gzip.encode(utf8.encode(jsonEncode(json)));
  return '${TransferQrPayload.prefix}'
      '${base64Url.encode(compressed).replaceAll('=', '')}';
}

Map<String, dynamic> _json({
  Object? v = 1,
  Object? t = 'offer',
  Object? sid = _sessionId,
  Object? from = _publicKey,
  Object? exp = 4102444800,
  Object? sdp = _sdp,
}) {
  return {'v': v, 't': t, 'sid': sid, 'from': from, 'exp': exp, 'sdp': sdp};
}

void main() {
  group('TransferQrPayload round trip', () {
    test('encodes and decodes an offer', () {
      final encoded = _payload().encode();
      expect(encoded, startsWith(TransferQrPayload.prefix));

      final decoded = TransferQrPayload.decode(encoded);
      expect(decoded.role, TransferQrRole.offer);
      expect(decoded.sessionId, _sessionId);
      expect(decoded.fromPublicKey, _publicKey);
      expect(decoded.expiresAt, 4102444800);
      expect(decoded.sdp, _sdp);
    });

    test('encodes and decodes an answer', () {
      final encoded = _payload(role: TransferQrRole.answer).encode();
      final decoded = TransferQrPayload.decode(encoded);
      expect(decoded.role, TransferQrRole.answer);
    });

    test('normalises uppercase hex to lowercase', () {
      final encoded = _payload(
        sessionId: _sessionId.toUpperCase(),
        from: _publicKey.toUpperCase(),
      ).encode();
      final decoded = TransferQrPayload.decode(encoded);
      expect(decoded.sessionId, _sessionId);
      expect(decoded.fromPublicKey, _publicKey);
    });

    test('accepts surrounding whitespace from a scanner', () {
      final encoded = '  ${_payload().encode()}\n';
      expect(TransferQrPayload.decode(encoded).sessionId, _sessionId);
    });
  });

  group('TransferQrPayload expiry', () {
    test('is not expired before the timestamp', () {
      final payload = _payload(expiresAt: 2000);
      expect(payload.isExpired(DateTime.fromMillisecondsSinceEpoch(1999000)), isFalse);
    });

    test('is expired at and after the timestamp', () {
      final payload = _payload(expiresAt: 2000);
      expect(payload.isExpired(DateTime.fromMillisecondsSinceEpoch(2000000)), isTrue);
      expect(payload.isExpired(DateTime.fromMillisecondsSinceEpoch(2001000)), isTrue);
    });
  });

  group('TransferQrPayload rejects', () {
    test('a foreign QR code', () {
      expect(
        () => TransferQrPayload.decode('https://example.com'),
        throwsA(isA<TransferQrException>()),
      );
    });

    test('an empty string', () {
      expect(
        () => TransferQrPayload.decode('   '),
        throwsA(isA<TransferQrException>()),
      );
    });

    test('malformed base64', () {
      expect(
        () => TransferQrPayload.decode('${TransferQrPayload.prefix}not*base64!'),
        throwsA(isA<TransferQrException>()),
      );
    });

    test('a truncated payload', () {
      final encoded = _payload().encode();
      expect(
        () => TransferQrPayload.decode(
          encoded.substring(0, encoded.length ~/ 2),
        ),
        throwsA(isA<TransferQrException>()),
      );
    });

    test('an oversized QR string before decoding', () {
      final huge = '${TransferQrPayload.prefix}${'a'.padRight(4000, 'a')}';
      expect(
        () => TransferQrPayload.decode(huge),
        throwsA(isA<TransferQrException>()),
      );
    });

    test('a payload that decompresses past the cap', () {
      final encoded = _encodeRaw(
        _json(sdp: 'v=0\nm=application ${'a'.padRight(64 * 1024, 'a')}'),
      );
      expect(encoded.length, lessThan(TransferQrPayload.maxEncodedLength));
      expect(
        () => TransferQrPayload.decode(encoded),
        throwsA(isA<TransferQrException>()),
      );
    });

    test('an unknown version', () {
      expect(
        () => TransferQrPayload.decode(_encodeRaw(_json(v: 2))),
        throwsA(isA<TransferQrException>()),
      );
    });

    test('an unknown role', () {
      expect(
        () => TransferQrPayload.decode(_encodeRaw(_json(t: 'chat'))),
        throwsA(isA<TransferQrException>()),
      );
    });

    test('a bad session id', () {
      expect(
        () => TransferQrPayload.decode(_encodeRaw(_json(sid: 'abc'))),
        throwsA(isA<TransferQrException>()),
      );
      expect(
        () => _payload(sessionId: 'zz').encode(),
        throwsA(isA<TransferQrException>()),
      );
    });

    test('a bad public key', () {
      expect(
        () => TransferQrPayload.decode(_encodeRaw(_json(from: _otherKey.substring(2)))),
        throwsA(isA<TransferQrException>()),
      );
      expect(
        () => _payload(from: 'not-a-key').encode(),
        throwsA(isA<TransferQrException>()),
      );
    });

    test('a missing or invalid expiry', () {
      expect(
        () => TransferQrPayload.decode(_encodeRaw(_json(exp: 0))),
        throwsA(isA<TransferQrException>()),
      );
      expect(
        () => _payload(expiresAt: 0).encode(),
        throwsA(isA<TransferQrException>()),
      );
    });

    test('an SDP without data channel media', () {
      expect(
        () => TransferQrPayload.decode(
          _encodeRaw(_json(sdp: 'v=0\na=ice-ufrag:abcd\n')),
        ),
        throwsA(isA<TransferQrException>()),
      );
    });

    test('an SDP without an ICE ufrag', () {
      expect(
        () => TransferQrPayload.decode(
          _encodeRaw(_json(sdp: 'v=0\nm=application 9 UDP/DTLS/SCTP\r\n')),
        ),
        throwsA(isA<TransferQrException>()),
      );
    });

    test('an SDP that is not a string', () {
      expect(
        () => TransferQrPayload.decode(_encodeRaw(_json(sdp: 5))),
        throwsA(isA<TransferQrException>()),
      );
    });

    test('a JSON value that is not an object', () {
      final compressed = gzip.encode(utf8.encode('[]'));
      final encoded = '${TransferQrPayload.prefix}'
          '${base64Url.encode(compressed).replaceAll('=', '')}';
      expect(
        () => TransferQrPayload.decode(encoded),
        throwsA(isA<TransferQrException>()),
      );
    });

    test('an oversized SDP on encode', () {
      expect(
        () => _payload(
          sdp:
              'v=0\nm=application ${'a'.padRight(TransferQrPayload.maxSdpLength, 'a')}',
        ).encode(),
        throwsA(isA<TransferQrException>()),
      );
    });
  });
}
