import 'dart:typed_data';

import 'package:curve_fault/crypto/curve256189.dart';
import 'package:curve_fault/models/transfer_manifest.dart';
import 'package:curve_fault/services/transfer/transfer_auth.dart';
import 'package:flutter_test/flutter_test.dart';

final Uint8List _aliceSeed = Uint8List.fromList(
  List<int>.generate(32, (index) => index + 1),
);
final Uint8List _bobSeed = Uint8List.fromList(
  List<int>.generate(32, (index) => 0xff - index),
);

final String _aliceKey = TransferAuth.hexOf(
  XEdDSA.generateKeyPair(_aliceSeed)['publicKey']!,
);
final String _bobKey = TransferAuth.hexOf(
  XEdDSA.generateKeyPair(_bobSeed)['publicKey']!,
);

const _sessionId = '00112233445566778899aabbccddeeff';
const _hash =
    '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';

TransferManifest _manifest({
  String? name,
  String? sender,
  String? recipient,
  int? containerSize,
}) {
  return TransferManifest(
    sessionId: _sessionId,
    name: name ?? 'notes.txt',
    mime: 'text/plain',
    size: 128,
    containerSize: containerSize ?? 512,
    sha256: _hash,
    senderPublicKey: sender ?? _aliceKey,
    recipientPublicKey: recipient ?? _bobKey,
    createdAt: 1700000000000,
  );
}

void main() {
  group('auth signatures', () {
    test('a sender signature verifies for the intended recipient', () async {
      final signature = await TransferAuth.signAuth(
        seed: _aliceSeed,
        sessionId: _sessionId,
        senderPublicKey: _aliceKey,
        recipientPublicKey: _bobKey,
      );

      expect(
        await TransferAuth.verifyAuth(
          signature: signature,
          sessionId: _sessionId,
          senderPublicKey: _aliceKey,
          recipientPublicKey: _bobKey,
        ),
        isTrue,
      );
    });

    test('an auth signature does not verify for another recipient', () async {
      final signature = await TransferAuth.signAuth(
        seed: _aliceSeed,
        sessionId: _sessionId,
        senderPublicKey: _aliceKey,
        recipientPublicKey: _bobKey,
      );

      expect(
        await TransferAuth.verifyAuth(
          signature: signature,
          sessionId: _sessionId,
          senderPublicKey: _aliceKey,
          recipientPublicKey: _aliceKey,
        ),
        isFalse,
      );
    });

    test('an auth signature does not verify for another session', () async {
      final signature = await TransferAuth.signAuth(
        seed: _aliceSeed,
        sessionId: _sessionId,
        senderPublicKey: _aliceKey,
        recipientPublicKey: _bobKey,
      );

      expect(
        await TransferAuth.verifyAuth(
          signature: signature,
          sessionId: 'ffeeddccbbaa99887766554433221100',
          senderPublicKey: _aliceKey,
          recipientPublicKey: _bobKey,
        ),
        isFalse,
      );
    });

    test('a tampered auth signature is rejected', () async {
      final signature = await TransferAuth.signAuth(
        seed: _aliceSeed,
        sessionId: _sessionId,
        senderPublicKey: _aliceKey,
        recipientPublicKey: _bobKey,
      );
      final bytes = TransferAuth.decodeSignature(signature)!;
      bytes[0] ^= 0x01;

      expect(
        await TransferAuth.verifyAuth(
          signature: TransferAuth.encodeSignature(bytes),
          sessionId: _sessionId,
          senderPublicKey: _aliceKey,
          recipientPublicKey: _bobKey,
        ),
        isFalse,
      );
    });

    test('a malformed auth signature is rejected', () async {
      expect(
        await TransferAuth.verifyAuth(
          signature: 'not-base64',
          sessionId: _sessionId,
          senderPublicKey: _aliceKey,
          recipientPublicKey: _bobKey,
        ),
        isFalse,
      );
      expect(
        await TransferAuth.verifyAuth(
          signature: '',
          sessionId: _sessionId,
          senderPublicKey: _aliceKey,
          recipientPublicKey: _bobKey,
        ),
        isFalse,
      );
    });
  });

  group('proof of possession', () {
    test('is signed by the recipient and verifies for the sender', () async {
      final signature = await TransferAuth.signProofOfPossession(
        seed: _bobSeed,
        sessionId: _sessionId,
        recipientPublicKey: _bobKey,
        senderPublicKey: _aliceKey,
      );

      expect(
        await TransferAuth.verifyProofOfPossession(
          signature: signature,
          sessionId: _sessionId,
          recipientPublicKey: _bobKey,
          senderPublicKey: _aliceKey,
        ),
        isTrue,
      );
    });

    test('fails when the expected sender differs', () async {
      final signature = await TransferAuth.signProofOfPossession(
        seed: _bobSeed,
        sessionId: _sessionId,
        recipientPublicKey: _bobKey,
        senderPublicKey: _aliceKey,
      );

      expect(
        await TransferAuth.verifyProofOfPossession(
          signature: signature,
          sessionId: _sessionId,
          recipientPublicKey: _bobKey,
          senderPublicKey: _bobKey,
        ),
        isFalse,
      );
    });

    test('a sender signature does not pass as a proof of possession', () async {
      final signature = await TransferAuth.signAuth(
        seed: _aliceSeed,
        sessionId: _sessionId,
        senderPublicKey: _aliceKey,
        recipientPublicKey: _bobKey,
      );

      expect(
        await TransferAuth.verifyProofOfPossession(
          signature: signature,
          sessionId: _sessionId,
          recipientPublicKey: _bobKey,
          senderPublicKey: _aliceKey,
        ),
        isFalse,
      );
    });
  });

  group('manifest signatures', () {
    test('a signed manifest verifies', () async {
      final manifest = _manifest();
      final signature = await TransferAuth.signManifest(
        manifest: manifest,
        seed: _aliceSeed,
      );

      expect(
        await TransferAuth.verifyManifest(
          manifest: manifest,
          signature: signature,
        ),
        isTrue,
      );
    });

    test('changing the file name invalidates the signature', () async {
      final manifest = _manifest();
      final signature = await TransferAuth.signManifest(
        manifest: manifest,
        seed: _aliceSeed,
      );

      expect(
        await TransferAuth.verifyManifest(
          manifest: _manifest(name: 'other.txt'),
          signature: signature,
        ),
        isFalse,
      );
    });

    test('changing the container size invalidates the signature', () async {
      final signature = await TransferAuth.signManifest(
        manifest: _manifest(),
        seed: _aliceSeed,
      );

      expect(
        await TransferAuth.verifyManifest(
          manifest: _manifest(containerSize: 513),
          signature: signature,
        ),
        isFalse,
      );
    });

    test('a manifest signed by someone else is rejected', () async {
      final signature = await TransferAuth.signManifest(
        manifest: _manifest(),
        seed: _bobSeed,
      );

      expect(
        await TransferAuth.verifyManifest(
          manifest: _manifest(),
          signature: signature,
        ),
        isFalse,
      );
    });
  });

  group('encoding helpers', () {
    test('hexOf round trips public keys', () {
      final publicKey = XEdDSA.generateKeyPair(_aliceSeed)['publicKey']!;
      final hex = TransferAuth.hexOf(publicKey);
      expect(hex, hasLength(64));
      expect(TransferAuth.publicKeyBytes(hex), publicKey);
    });

    test('publicKeyBytes rejects malformed keys', () {
      expect(TransferAuth.publicKeyBytes(''), isNull);
      expect(TransferAuth.publicKeyBytes('zz'.padRight(64, 'z')), isNull);
      expect(TransferAuth.publicKeyBytes(_aliceKey.substring(2)), isNull);
    });

    test('decodeSignature rejects the wrong length and bad base64', () {
      expect(TransferAuth.decodeSignature('AAAA'), isNull);
      expect(TransferAuth.decodeSignature('!!!'), isNull);
      expect(
        TransferAuth.decodeSignature(
          TransferAuth.encodeSignature(Uint8List(XEdDSA.signatureLength)),
        ),
        hasLength(XEdDSA.signatureLength),
      );
    });

    test('constantTimeEquals compares length and contents', () {
      expect(TransferAuth.constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(TransferAuth.constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
      expect(TransferAuth.constantTimeEquals([1, 2], [1, 2, 3]), isFalse);
      expect(TransferAuth.constantTimeEquals([], []), isTrue);
    });

    test('constantTimeEqualsHex ignores case and rejects different values', () {
      expect(
        TransferAuth.constantTimeEqualsHex('aabbcc', 'AABBCC'),
        isTrue,
      );
      expect(
        TransferAuth.constantTimeEqualsHex('aabbcc', 'aabbcd'),
        isFalse,
      );
    });
  });
}
