import 'dart:io';
import 'dart:typed_data';

import 'package:curve_fault/services/vault_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late Uint8List vaultKey;
  late String containerPath;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('curvevault_tamper_test_');
    vaultKey = VaultCrypto.deriveVaultKey(
      Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
    );
    final inputPath = '${tempDir.path}/doc.bin';
    containerPath = '${tempDir.path}/doc.cvlt';
    File(inputPath).writeAsBytesSync(
      List<int>.generate(2048 + 17, (i) => (i * 31) % 256),
    );
    await VaultCrypto.encryptFile(
      inputPath: inputPath,
      outputPath: containerPath,
      vaultKey: vaultKey,
      metadata: {'name': 'doc.bin', 'mime': 'application/octet-stream'},
      chunkSize: 1024,
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Uint8List readContainer() => File(containerPath).readAsBytesSync();

  test('an untouched container verifies', () async {
    final info = await VaultCrypto.verifyFile(
      containerPath: containerPath,
      vaultKey: vaultKey,
    );
    expect(info.plaintextLength, 2048 + 17);
  });

  test('a flipped body byte fails verification', () async {
    final bytes = readContainer();
    bytes[bytes.length - 1] ^= 0x01;
    File(containerPath).writeAsBytesSync(bytes);

    await expectLater(
      VaultCrypto.verifyFile(containerPath: containerPath, vaultKey: vaultKey),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test('a truncated container fails verification', () async {
    final bytes = readContainer();
    File(containerPath).writeAsBytesSync(bytes.sublist(0, bytes.length - 10));

    await expectLater(
      VaultCrypto.verifyFile(containerPath: containerPath, vaultKey: vaultKey),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test('trailing garbage fails verification', () async {
    final bytes = readContainer();
    File(containerPath).writeAsBytesSync([...bytes, 1, 2, 3, 4, 5]);

    await expectLater(
      VaultCrypto.verifyFile(containerPath: containerPath, vaultKey: vaultKey),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test('a changed header field breaks the key slot', () {
    final bytes = readContainer();
    bytes[10] ^= 0x01;
    File(containerPath).writeAsBytesSync(bytes);

    expect(
      () => VaultCrypto.readInfo(
        containerPath: containerPath,
        vaultKey: vaultKey,
      ),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test('a changed metadata byte fails the metadata check', () {
    final bytes = readContainer();
    // 20 fixed header + 93 slot + 12 nonce + 4 length = metadata ciphertext.
    bytes[130] ^= 0x01;
    File(containerPath).writeAsBytesSync(bytes);

    expect(
      () => VaultCrypto.readInfo(
        containerPath: containerPath,
        vaultKey: vaultKey,
      ),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test('a decrypt of a tampered container leaves no output file', () async {
    final bytes = readContainer();
    bytes[bytes.length - 1] ^= 0x01;
    File(containerPath).writeAsBytesSync(bytes);
    final outputPath = '${tempDir.path}/doc.out';

    await expectLater(
      VaultCrypto.decryptFile(
        containerPath: containerPath,
        outputPath: outputPath,
        vaultKey: vaultKey,
      ),
      throwsA(isA<VaultCryptoException>()),
    );
    expect(File(outputPath).existsSync(), isFalse);
  });
}
