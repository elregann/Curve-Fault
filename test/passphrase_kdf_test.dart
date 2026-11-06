import 'dart:convert';
import 'dart:typed_data';

import 'package:curve_fault/crypto/curve256189.dart';
import 'package:curve_fault/crypto/passphrase_kdf.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Argon2id', () {
    test('matches an independent Argon2id v1.3 known-answer vector', () {
      // Generated with OpenSSL's Argon2id implementation (Node 24 crypto.argon2Sync)
      // using the same password, salt, and OWASP parameters.
      final salt = Uint8List.fromList(List.generate(16, (i) => i));
      final key = deriveArgon2idKey(
        passphrase: 'curve-vault-test-passphrase',
        salt: salt,
        params: Argon2idParams.standard,
      );

      expect(
        key.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '3835554f6ce32842a4b91a0c9fd182d78004463c8e1414209dca8e326161b7a7',
      );
    });

    test('produces different keys for different salts', () {
      const params = Argon2idParams(
        memoryKiB: 8 * 1024,
        iterations: 1,
        parallelism: 1,
      );
      final first = deriveArgon2idKey(
        passphrase: 'same passphrase',
        salt: Uint8List(16),
        params: params,
      );
      final second = deriveArgon2idKey(
        passphrase: 'same passphrase',
        salt: Uint8List(16)..fillRange(0, 16, 1),
        params: params,
      );

      expect(first, isNot(equals(second)));
    });

    test('produces different keys when the cost changes', () {
      final salt = Uint8List(16)..fillRange(0, 16, 3);
      final first = deriveArgon2idKey(
        passphrase: 'same passphrase',
        salt: salt,
        params: const Argon2idParams(
          memoryKiB: 8 * 1024,
          iterations: 1,
          parallelism: 1,
        ),
      );
      final second = deriveArgon2idKey(
        passphrase: 'same passphrase',
        salt: salt,
        params: const Argon2idParams(
          memoryKiB: 8 * 1024,
          iterations: 2,
          parallelism: 1,
        ),
      );

      expect(first, isNot(equals(second)));
    });

    test('rejects unsafe or malformed parameters', () {
      expect(
        () => const Argon2idParams(
          memoryKiB: 1024,
          iterations: 1,
          parallelism: 1,
        ).validate(),
        throwsArgumentError,
      );
      expect(
        () => const Argon2idParams(
          memoryKiB: 19 * 1024,
          iterations: 0,
          parallelism: 1,
        ).validate(),
        throwsArgumentError,
      );
      expect(
        () => const Argon2idParams(
          memoryKiB: 19 * 1024,
          iterations: 2,
          parallelism: 0,
        ).validate(),
        throwsArgumentError,
      );
      expect(
        () => Argon2idParams.fromJson({'m': '19456', 't': 2, 'p': 1}),
        throwsFormatException,
      );
    });

    test('round-trips its serialized parameters', () {
      final encoded = Argon2idParams.standard.toJson();
      expect(Argon2idParams.fromJson(encoded), Argon2idParams.standard);
    });
  });

  group('seed AAD', () {
    test('binds the record version and the KDF parameters', () {
      final standard = seedKdfAad(Argon2idParams.standard);
      final cheaper = seedKdfAad(
        const Argon2idParams(
          memoryKiB: 8 * 1024,
          iterations: 1,
          parallelism: 1,
        ),
      );

      expect(utf8.decode(standard), contains('CurveVault-seed-v2'));
      expect(utf8.decode(standard), contains('m=19456'));
      expect(standard, isNot(equals(cheaper)));
    });

    test('AES-GCM rejects seed ciphertext when the AAD params change', () {
      final key = Uint8List(32)..fillRange(0, 32, 7);
      final seed = Uint8List(32)..fillRange(0, 32, 9);
      final nonce = Uint8List(12);
      final encrypted = AESGCM.encrypt(
        key: key,
        nonce: nonce,
        plaintext: seed,
        aad: seedKdfAad(Argon2idParams.standard),
      );
      final ciphertext = Uint8List.fromList(encrypted.ciphertext);
      final tag = Uint8List.fromList(encrypted.tag);

      final accepted = AESGCM.decrypt(
        key: key,
        nonce: nonce,
        ciphertext: ciphertext,
        tag: tag,
        aad: seedKdfAad(Argon2idParams.standard),
      );
      expect(accepted, equals(seed));

      final rejected = AESGCM.decrypt(
        key: key,
        nonce: nonce,
        ciphertext: ciphertext,
        tag: tag,
        aad: seedKdfAad(
          const Argon2idParams(
            memoryKiB: 8 * 1024,
            iterations: 1,
            parallelism: 1,
          ),
        ),
      );
      expect(rejected, isNull);
    });
  });
}
