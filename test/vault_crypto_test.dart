import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:curve_fault/crypto/curve256189.dart';
import 'package:curve_fault/services/vault_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('curvevault_crypto_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('encrypts, verifies, and decrypts a multi-chunk file', () async {
    final seed = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final vaultKey = VaultCrypto.deriveVaultKey(seed);

    final plaintext = Uint8List.fromList(
      List<int>.generate(3 * 1024 * 1024 + 123, (i) => i % 251),
    );
    final inputPath = '${tempDir.path}/photo.png';
    final containerPath = '${tempDir.path}/photo.cvlt';
    final outputPath = '${tempDir.path}/photo.out';
    File(inputPath).writeAsBytesSync(plaintext);

    final metadata = {
      'id': 'abc123',
      'name': 'photo.png',
      'mime': 'image/png',
      'relativePath': 'DCIM/Camera/photo.png',
      'addedAt': 123456789,
    };

    final encrypted = await VaultCrypto.encryptFile(
      inputPath: inputPath,
      outputPath: containerPath,
      vaultKey: vaultKey,
      metadata: metadata,
      chunkSize: 1024 * 1024,
    );

    expect(encrypted.plaintextLength, plaintext.length);
    expect(encrypted.metadata['name'], 'photo.png');
    expect(File(containerPath).lengthSync(), greaterThan(plaintext.length));

    final info = VaultCrypto.readInfo(
      containerPath: containerPath,
      vaultKey: vaultKey,
    );
    expect(info.metadata['id'], 'abc123');
    expect(info.metadata['size'], plaintext.length);

    final verified = await VaultCrypto.verifyFile(
      containerPath: containerPath,
      vaultKey: vaultKey,
    );
    expect(verified.plaintextLength, plaintext.length);

    await VaultCrypto.decryptFile(
      containerPath: containerPath,
      outputPath: outputPath,
      vaultKey: vaultKey,
    );
    expect(File(outputPath).readAsBytesSync(), plaintext);
  });

  test('rejects a wrong vault key', () async {
    final vaultKey = VaultCrypto.deriveVaultKey(
      Uint8List.fromList(List<int>.generate(32, (i) => i)),
    );
    final wrongKey = VaultCrypto.deriveVaultKey(
      Uint8List.fromList(List<int>.generate(32, (i) => 255 - i)),
    );
    final inputPath = '${tempDir.path}/secret.txt';
    final containerPath = '${tempDir.path}/secret.cvlt';
    File(inputPath).writeAsStringSync('hello curve vault');

    await VaultCrypto.encryptFile(
      inputPath: inputPath,
      outputPath: containerPath,
      vaultKey: vaultKey,
      metadata: {'name': 'secret.txt', 'mime': 'text/plain'},
    );

    expect(
      () => VaultCrypto.readInfo(
        containerPath: containerPath,
        vaultKey: wrongKey,
      ),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test('supports an empty file', () async {
    final vaultKey = VaultCrypto.deriveVaultKey(Uint8List(32));
    final inputPath = '${tempDir.path}/empty.bin';
    final containerPath = '${tempDir.path}/empty.cvlt';
    final outputPath = '${tempDir.path}/empty.out';
    File(inputPath).writeAsBytesSync(<int>[]);

    await VaultCrypto.encryptFile(
      inputPath: inputPath,
      outputPath: containerPath,
      vaultKey: vaultKey,
      metadata: {'name': 'empty.bin', 'mime': 'application/octet-stream'},
    );
    await VaultCrypto.decryptFile(
      containerPath: containerPath,
      outputPath: outputPath,
      vaultKey: vaultKey,
    );
    expect(File(outputPath).lengthSync(), 0);
  });

  test('recipient can open a shared container with their identity key', () async {
    final ownerSeed = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final ownerVaultKey = VaultCrypto.deriveVaultKey(ownerSeed);

    final recipientSeed = Uint8List.fromList(
      List<int>.generate(32, (i) => (i * 7 + 3) % 256),
    );
    final recipientPublic = X256189.generateKeyPair(recipientSeed)['publicKey']!;

    final plaintext = Uint8List.fromList(
      List<int>.generate(4096, (i) => Random(i).nextInt(256)),
    );
    final inputPath = '${tempDir.path}/shared.bin';
    final containerPath = '${tempDir.path}/shared.cvlt';
    final outputPath = '${tempDir.path}/shared.out';
    File(inputPath).writeAsBytesSync(plaintext);

    await VaultCrypto.encryptFile(
      inputPath: inputPath,
      outputPath: containerPath,
      vaultKey: ownerVaultKey,
      metadata: {'name': 'shared.bin', 'mime': 'application/octet-stream'},
      recipientPublicKey: recipientPublic,
    );

    // The recipient has a different vault key; only their identity slot works.
    final recipientVaultKey = VaultCrypto.deriveVaultKey(recipientSeed);
    final info = VaultCrypto.readInfo(
      containerPath: containerPath,
      vaultKey: recipientVaultKey,
      privateKey: recipientSeed,
    );
    expect(info.hasRecipientSlot, isTrue);
    expect(info.metadata['name'], 'shared.bin');

    await VaultCrypto.decryptFile(
      containerPath: containerPath,
      outputPath: outputPath,
      vaultKey: recipientVaultKey,
      privateKey: recipientSeed,
    );
    expect(File(outputPath).readAsBytesSync(), plaintext);
  });
}
