import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../crypto/curve256189.dart';

/// Thrown when a vault container is malformed or cannot be unlocked.
class VaultCryptoException implements Exception {
  VaultCryptoException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Metadata and format information read from a `.cvlt` container.
class VaultContainerInfo {
  const VaultContainerInfo({
    required this.metadata,
    required this.plaintextLength,
    required this.chunkSize,
    required this.hasRecipientSlot,
  });

  final Map<String, dynamic> metadata;
  final int plaintextLength;
  final int chunkSize;
  final bool hasRecipientSlot;

  Map<String, dynamic> toMap() {
    return {
      'metadata': metadata,
      'plaintextLength': plaintextLength,
      'chunkSize': chunkSize,
      'hasRecipientSlot': hasRecipientSlot,
    };
  }

  factory VaultContainerInfo.fromMap(Map<dynamic, dynamic> map) {
    return VaultContainerInfo(
      metadata: Map<String, dynamic>.from(map['metadata'] as Map),
      plaintextLength: (map['plaintextLength'] as num).toInt(),
      chunkSize: (map['chunkSize'] as num).toInt(),
      hasRecipientSlot: map['hasRecipientSlot'] as bool? ?? false,
    );
  }
}

/// Pluggable bulk-content cipher.
///
/// Production uses native Android AES-GCM for speed. Tests and other
/// platforms use the pure-Dart fallback.
abstract class ContentCipher {
  Future<void> encryptChunks({
    required String inputPath,
    required String outputPath,
    required Uint8List fileKey,
    required Uint8List headerHash,
    required int chunkSize,
    required bool append,
  });

  Future<void> decryptChunks({
    required String containerPath,
    required String outputPath,
    required Uint8List fileKey,
    required Uint8List headerHash,
    required int plaintextLength,
    required int chunkSize,
    required int chunkOffset,
  });

  Future<void> verifyChunks({
    required String containerPath,
    required Uint8List fileKey,
    required Uint8List headerHash,
    required int plaintextLength,
    required int chunkSize,
    required int chunkOffset,
  });
}

/// In-place, chunked AES-256-GCM container used by CurveVault.
///
/// Layout (little-endian, version 1):
///
///   magic "CFV1" | version | flags | slotCount | reserved
///   chunkSize (u32) | plaintextLength (u64)
///   slots[slotCount]  (type, nonce[12], ephemeralPublic[32], wrappedKey[48])
///   metaNonce[12] | metaLength (u32) | metaCiphertext + tag
///   chunks: nonce[12] | ciphertextLength (u32) | ciphertext | tag[16]
///
/// A random 32-byte file key encrypts the content. The file key is wrapped
/// once for the local vault key and, optionally, once for a Curve256189
/// recipient identity. Bulk data never touches the expensive curve code.
class VaultCrypto {
  VaultCrypto._();

  static const List<int> _magic = [0x43, 0x46, 0x56, 0x31]; // "CFV1"
  static const int _version = 1;
  static const int _fixedHeaderLength = 20;
  static const int _slotLength = 93;
  static const int _tagLength = 16;
  static const int defaultChunkSize = 1024 * 1024;

  /// Bulk-content implementation used when a caller does not pass [cipher].
  ///
  /// The Android app installs a native AES-GCM cipher at startup; tests and
  /// desktop builds fall back to [DartContentCipher].
  static ContentCipher? defaultCipher;

  static final Random _random = Random.secure();

  static Uint8List randomBytes(int length) {
    return Uint8List.fromList(
      List<int>.generate(length, (_) => _random.nextInt(256)),
    );
  }

  /// Derives the symmetric vault key from the 32-byte master seed.
  static Uint8List deriveVaultKey(Uint8List masterSeed) {
    if (masterSeed.length != 32) {
      throw VaultCryptoException('Master seed must be 32 bytes');
    }
    return HKDF.derive(
      ikm: masterSeed,
      salt: Uint8List.fromList(utf8.encode('CurveVault-v1')),
      info: Uint8List.fromList(utf8.encode('vault-key')),
      length: 32,
    );
  }

  static Uint8List _deriveShareKey(Uint8List sharedSecret) {
    return HKDF.derive(
      ikm: sharedSecret,
      salt: Uint8List.fromList(utf8.encode('CurveVault-v1')),
      info: Uint8List.fromList(utf8.encode('share-key')),
      length: 32,
    );
  }

  /// Encrypts [inputPath] into a new container at [outputPath].
  ///
  /// When [recipientPublicKey] is supplied, a second key slot is added so the
  /// recipient can unwrap the file key with their Curve256189 identity.
  static Future<VaultContainerInfo> encryptFile({
    required String inputPath,
    required String outputPath,
    required Uint8List vaultKey,
    required Map<String, dynamic> metadata,
    Uint8List? recipientPublicKey,
    int chunkSize = defaultChunkSize,
    ContentCipher? cipher,
  }) async {
    _requireKey(vaultKey);
    if (chunkSize < 1024 || chunkSize > 16 * 1024 * 1024) {
      throw VaultCryptoException('Invalid chunk size');
    }
    if (recipientPublicKey != null && recipientPublicKey.length != 32) {
      throw VaultCryptoException('Recipient public key must be 32 bytes');
    }

    final input = File(inputPath);
    if (!input.existsSync()) {
      throw VaultCryptoException('Input file does not exist');
    }
    final plaintextLength = input.lengthSync();
    final fileKey = randomBytes(32);
    final slotCount = recipientPublicKey == null ? 1 : 2;

    final prefix = _buildPrefix(
      slotCount: slotCount,
      chunkSize: chunkSize,
      plaintextLength: plaintextLength,
    );

    final slots = <_KeySlot>[];

    // Slot 0: the local vault key.
    final vaultNonce = randomBytes(12);
    final vaultAad = _slotAad(prefix, 0, vaultNonce, Uint8List(32));
    final vaultWrapped = AESGCM.encrypt(
      key: vaultKey,
      nonce: vaultNonce,
      plaintext: fileKey,
      aad: vaultAad,
    );
    slots.add(
      _KeySlot(
        type: 0,
        nonce: vaultNonce,
        ephemeralPublic: Uint8List(32),
        wrappedKey: Uint8List.fromList([
          ...vaultWrapped.ciphertext,
          ...vaultWrapped.tag,
        ]),
      ),
    );

    // Slot 1 (optional): a Curve256189 recipient.
    if (recipientPublicKey != null) {
      final ephemeralSeed = randomBytes(32);
      final ephemeralKeyPair = X256189.generateKeyPair(ephemeralSeed);
      final ephemeralPublic = ephemeralKeyPair['publicKey']!;
      final shared = X256189.computeSharedSecret(
        ephemeralSeed,
        recipientPublicKey,
      );
      if (shared == null) {
        throw VaultCryptoException('Invalid recipient public key');
      }
      final shareKey = _deriveShareKey(shared);
      final shareNonce = randomBytes(12);
      final shareAad = _slotAad(prefix, 1, shareNonce, ephemeralPublic);
      final shareWrapped = AESGCM.encrypt(
        key: shareKey,
        nonce: shareNonce,
        plaintext: fileKey,
        aad: shareAad,
      );
      slots.add(
        _KeySlot(
          type: 1,
          nonce: shareNonce,
          ephemeralPublic: ephemeralPublic,
          wrappedKey: Uint8List.fromList([
            ...shareWrapped.ciphertext,
            ...shareWrapped.tag,
          ]),
        ),
      );
    }

    final slotsBytes = Uint8List.fromList(
      slots.expand((slot) => slot.toBytes()).toList(),
    );
    final metadataAad = Uint8List.fromList([...prefix, ...slotsBytes]);

    final metaMap = Map<String, dynamic>.from(metadata);
    metaMap['size'] = plaintextLength;
    final metaJson = Uint8List.fromList(utf8.encode(jsonEncode(metaMap)));
    final metaNonce = randomBytes(12);
    final metaEncrypted = AESGCM.encrypt(
      key: fileKey,
      nonce: metaNonce,
      plaintext: metaJson,
      aad: metadataAad,
    );
    final metaLength = metaEncrypted.ciphertext.length + _tagLength;

    final output = File(outputPath).openSync(mode: FileMode.write);
    Uint8List headerHash;
    try {
      output.writeFromSync(prefix);
      output.writeFromSync(slotsBytes);
      output.writeFromSync(metaNonce);
      output.writeFromSync(_u32(metaLength));
      output.writeFromSync(metaEncrypted.ciphertext);
      output.writeFromSync(metaEncrypted.tag);

      headerHash = Uint8List.fromList(
        sha256
            .convert([
              ...prefix,
              ...slotsBytes,
              ...metaNonce,
              ..._u32(metaLength),
              ...metaEncrypted.ciphertext,
              ...metaEncrypted.tag,
            ])
            .bytes,
      );
    } catch (_) {
      output.closeSync();
      try {
        File(outputPath).deleteSync();
      } catch (_) {
        // Best-effort cleanup.
      }
      rethrow;
    }
    output.closeSync();

    try {
      await (cipher ?? defaultCipher ?? DartContentCipher.instance)
          .encryptChunks(
        inputPath: inputPath,
        outputPath: outputPath,
        fileKey: fileKey,
        headerHash: headerHash,
        chunkSize: chunkSize,
        append: true,
      );
    } catch (_) {
      try {
        File(outputPath).deleteSync();
      } catch (_) {
        // Best-effort cleanup.
      }
      rethrow;
    }

    return VaultContainerInfo(
      metadata: metaMap,
      plaintextLength: plaintextLength,
      chunkSize: chunkSize,
      hasRecipientSlot: recipientPublicKey != null,
    );
  }

  /// Reads metadata without decrypting the file body.
  static VaultContainerInfo readInfo({
    required String containerPath,
    required Uint8List vaultKey,
    Uint8List? privateKey,
  }) {
    _requireKey(vaultKey);
    final input = File(containerPath).openSync(mode: FileMode.read);
    try {
      final header = _readHeader(input);
      final fileKey = _unwrapFileKey(header, vaultKey, privateKey);
      if (fileKey == null) {
        throw VaultCryptoException('This file is not encrypted for this key');
      }
      final metadata = _decryptMetadata(header, fileKey);
      return VaultContainerInfo(
        metadata: metadata,
        plaintextLength: header.plaintextLength,
        chunkSize: header.chunkSize,
        hasRecipientSlot: header.slots.any((slot) => slot.type == 1),
      );
    } finally {
      input.closeSync();
    }
  }

  /// Decrypts [containerPath] to [outputPath].
  static Future<VaultContainerInfo> decryptFile({
    required String containerPath,
    required String outputPath,
    required Uint8List vaultKey,
    Uint8List? privateKey,
    ContentCipher? cipher,
  }) async {
    _requireKey(vaultKey);
    final input = File(containerPath).openSync(mode: FileMode.read);
    late _ContainerHeader header;
    late Uint8List fileKey;
    late Map<String, dynamic> metadata;
    late int chunkOffset;
    try {
      header = _readHeader(input);
      final unwrapped = _unwrapFileKey(header, vaultKey, privateKey);
      if (unwrapped == null) {
        throw VaultCryptoException('This file is not encrypted for this key');
      }
      fileKey = unwrapped;
      metadata = _decryptMetadata(header, fileKey);
      chunkOffset = input.positionSync();
    } finally {
      input.closeSync();
    }

    try {
      await (cipher ?? defaultCipher ?? DartContentCipher.instance)
          .decryptChunks(
        containerPath: containerPath,
        outputPath: outputPath,
        fileKey: fileKey,
        headerHash: Uint8List.fromList(header.headerHash),
        plaintextLength: header.plaintextLength,
        chunkSize: header.chunkSize,
        chunkOffset: chunkOffset,
      );
    } catch (_) {
      try {
        File(outputPath).deleteSync();
      } catch (_) {
        // Best-effort cleanup.
      }
      rethrow;
    }

    return VaultContainerInfo(
      metadata: metadata,
      plaintextLength: header.plaintextLength,
      chunkSize: header.chunkSize,
      hasRecipientSlot: header.slots.any((slot) => slot.type == 1),
    );
  }

  /// Verifies every chunk of a container without writing plaintext.
  static Future<VaultContainerInfo> verifyFile({
    required String containerPath,
    required Uint8List vaultKey,
    Uint8List? privateKey,
    ContentCipher? cipher,
  }) async {
    _requireKey(vaultKey);
    final input = File(containerPath).openSync(mode: FileMode.read);
    late _ContainerHeader header;
    late Uint8List fileKey;
    late Map<String, dynamic> metadata;
    late int chunkOffset;
    try {
      header = _readHeader(input);
      final unwrapped = _unwrapFileKey(header, vaultKey, privateKey);
      if (unwrapped == null) {
        throw VaultCryptoException('This file is not encrypted for this key');
      }
      fileKey = unwrapped;
      metadata = _decryptMetadata(header, fileKey);
      chunkOffset = input.positionSync();
    } finally {
      input.closeSync();
    }

    await (cipher ?? defaultCipher ?? DartContentCipher.instance)
        .verifyChunks(
      containerPath: containerPath,
      fileKey: fileKey,
      headerHash: Uint8List.fromList(header.headerHash),
      plaintextLength: header.plaintextLength,
      chunkSize: header.chunkSize,
      chunkOffset: chunkOffset,
    );

    return VaultContainerInfo(
      metadata: metadata,
      plaintextLength: header.plaintextLength,
      chunkSize: header.chunkSize,
      hasRecipientSlot: header.slots.any((slot) => slot.type == 1),
    );
  }

  static _ContainerHeader _readHeader(RandomAccessFile input) {
    final fixed = _readExactly(input, _fixedHeaderLength);
    for (var i = 0; i < _magic.length; i++) {
      if (fixed[i] != _magic[i]) {
        throw VaultCryptoException('Not a CurveVault container');
      }
    }
    if (fixed[4] != _version) {
      throw VaultCryptoException('Unsupported container version');
    }

    final slotCount = fixed[6];
    if (slotCount < 1 || slotCount > 2) {
      throw VaultCryptoException('Invalid key slot count');
    }

    final chunkSize = _readU32(fixed, 8);
    final plaintextLength = _readU64(fixed, 12);
    if (chunkSize < 1024 || chunkSize > 16 * 1024 * 1024) {
      throw VaultCryptoException('Invalid chunk size in container');
    }
    if (plaintextLength < 0) {
      throw VaultCryptoException('Invalid plaintext length');
    }

    final prefix = Uint8List.fromList(fixed);

    final slots = <_KeySlot>[];
    for (var i = 0; i < slotCount; i++) {
      final raw = _readExactly(input, _slotLength);
      final type = raw[0];
      if (type != 0 && type != 1) {
        throw VaultCryptoException('Unknown key slot type');
      }
      slots.add(
        _KeySlot(
          type: type,
          nonce: Uint8List.fromList(raw.sublist(1, 13)),
          ephemeralPublic: Uint8List.fromList(raw.sublist(13, 45)),
          wrappedKey: Uint8List.fromList(raw.sublist(45, 93)),
        ),
      );
    }

    final slotsBytes = Uint8List.fromList(
      slots.expand((slot) => slot.toBytes()).toList(),
    );
    final metadataAad = Uint8List.fromList([...prefix, ...slotsBytes]);

    final metaNonce = _readExactly(input, 12);
    final metaLength = _readU32(_readExactly(input, 4), 0);
    if (metaLength < _tagLength) {
      throw VaultCryptoException('Invalid metadata length');
    }
    final metaCiphertextWithTag = _readExactly(input, metaLength);
    final metaCiphertext = Uint8List.fromList(
      metaCiphertextWithTag.sublist(0, metaLength - _tagLength),
    );
    final metaTag = Uint8List.fromList(
      metaCiphertextWithTag.sublist(metaLength - _tagLength),
    );

    final headerHash = sha256
        .convert([
          ...prefix,
          ...slotsBytes,
          ...metaNonce,
          ..._u32(metaLength),
          ...metaCiphertextWithTag,
        ])
        .bytes;

    return _ContainerHeader(
      prefix: prefix,
      slots: slots,
      metadataAad: metadataAad,
      metaNonce: metaNonce,
      metaCiphertext: metaCiphertext,
      metaTag: metaTag,
      headerHash: headerHash,
      plaintextLength: plaintextLength,
      chunkSize: chunkSize,
    );
  }

  static Uint8List? _unwrapFileKey(
    _ContainerHeader header,
    Uint8List? vaultKey,
    Uint8List? privateKey,
  ) {
    for (final slot in header.slots) {
      Uint8List? wrappingKey;
      if (slot.type == 0 && vaultKey != null) {
        wrappingKey = vaultKey;
      } else if (slot.type == 1 && privateKey != null) {
        final shared = X256189.computeSharedSecret(
          privateKey,
          slot.ephemeralPublic,
        );
        if (shared == null) continue;
        wrappingKey = _deriveShareKey(shared);
      }

      if (wrappingKey == null) continue;

      final aad = _slotAad(
        header.prefix,
        slot.type,
        slot.nonce,
        slot.ephemeralPublic,
      );
      final fileKey = AESGCM.decrypt(
        key: wrappingKey,
        nonce: slot.nonce,
        ciphertext: Uint8List.fromList(slot.wrappedKey.sublist(0, 32)),
        tag: Uint8List.fromList(slot.wrappedKey.sublist(32, 48)),
        aad: aad,
      );
      if (fileKey != null && fileKey.length == 32) {
        return fileKey;
      }
    }
    return null;
  }

  static Map<String, dynamic> _decryptMetadata(
    _ContainerHeader header,
    Uint8List fileKey,
  ) {
    final plaintext = AESGCM.decrypt(
      key: fileKey,
      nonce: header.metaNonce,
      ciphertext: header.metaCiphertext,
      tag: header.metaTag,
      aad: header.metadataAad,
    );
    if (plaintext == null) {
      throw VaultCryptoException('Metadata integrity check failed');
    }
    try {
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Fall through to the format error below.
    }
    throw VaultCryptoException('Invalid metadata');
  }

  static Uint8List _buildPrefix({
    required int slotCount,
    required int chunkSize,
    required int plaintextLength,
  }) {
    final builder = BytesBuilder(copy: false)
      ..add(_magic)
      ..addByte(_version)
      ..addByte(0) // flags
      ..addByte(slotCount)
      ..addByte(0) // reserved
      ..add(_u32(chunkSize))
      ..add(_u64(plaintextLength));
    return builder.toBytes();
  }

  static Uint8List _slotAad(
    Uint8List prefix,
    int type,
    Uint8List nonce,
    Uint8List ephemeralPublic,
  ) {
    return Uint8List.fromList([
      ...prefix,
      type,
      ...nonce,
      ...ephemeralPublic,
    ]);
  }

  static Uint8List _readExactly(RandomAccessFile file, int length) {
    if (length == 0) return Uint8List(0);
    final buffer = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      final read = file.readIntoSync(buffer, offset, length - offset);
      if (read <= 0) {
        throw VaultCryptoException('Unexpected end of container');
      }
      offset += read;
    }
    return buffer;
  }

  static Uint8List _u32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  static Uint8List _u64(int value) {
    final data = ByteData(8)..setUint64(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  static int _readU32(Uint8List bytes, int offset) {
    return ByteData.sublistView(bytes, offset, offset + 4)
        .getUint32(0, Endian.little);
  }

  static int _readU64(Uint8List bytes, int offset) {
    return ByteData.sublistView(bytes, offset, offset + 8)
        .getUint64(0, Endian.little);
  }

  static void _requireKey(Uint8List key) {
    if (key.length != 32) {
      throw VaultCryptoException('AES-256 key must be 32 bytes');
    }
  }

  static Uint8List chunkAad(Uint8List headerHash, int index) {
    return Uint8List.fromList([
      ...headerHash,
      ..._u64(index),
    ]);
  }

  static void _processChunksRaw({
    required RandomAccessFile input,
    required RandomAccessFile? output,
    required Uint8List fileKey,
    required Uint8List headerHash,
    required int plaintextLength,
    required int chunkSize,
  }) {
    var index = 0;
    var total = 0;

    while (true) {
      final nonce = input.readSync(12);
      if (nonce.isEmpty) break;
      if (nonce.length != 12) {
        throw VaultCryptoException('Corrupt chunk header');
      }

      final lengthBytes = input.readSync(4);
      if (lengthBytes.length != 4) {
        throw VaultCryptoException('Corrupt chunk length');
      }
      final ciphertextLength = _readU32(lengthBytes, 0);
      if (ciphertextLength > chunkSize + 16) {
        throw VaultCryptoException('Invalid chunk length');
      }

      final ciphertext = _readExactly(input, ciphertextLength);
      final tag = _readExactly(input, _tagLength);
      final plaintext = AESGCM.decrypt(
        key: fileKey,
        nonce: nonce,
        ciphertext: ciphertext,
        tag: tag,
        aad: chunkAad(headerHash, index),
      );
      if (plaintext == null) {
        throw VaultCryptoException('Integrity check failed at chunk $index');
      }

      output?.writeFromSync(plaintext);
      total += plaintext.length;
      index++;
    }

    if (total != plaintextLength) {
      throw VaultCryptoException('Container is truncated or padded');
    }
  }
}

/// Pure-Dart fallback. Correct but slow; used by tests and non-Android builds.
class DartContentCipher implements ContentCipher {
  DartContentCipher._();

  static final DartContentCipher instance = DartContentCipher._();

  @override
  Future<void> encryptChunks({
    required String inputPath,
    required String outputPath,
    required Uint8List fileKey,
    required Uint8List headerHash,
    required int chunkSize,
    required bool append,
  }) async {
    final input = File(inputPath).openSync(mode: FileMode.read);
    final output = File(outputPath).openSync(
      mode: append ? FileMode.append : FileMode.write,
    );
    try {
      var index = 0;
      var remaining = File(inputPath).lengthSync();
      while (remaining > 0) {
        final toRead = min(chunkSize, remaining);
        final chunk = VaultCrypto._readExactly(input, toRead);
        final nonce = VaultCrypto.randomBytes(12);
        final encrypted = AESGCM.encrypt(
          key: fileKey,
          nonce: nonce,
          plaintext: chunk,
          aad: VaultCrypto.chunkAad(headerHash, index),
        );
        output.writeFromSync(nonce);
        output.writeFromSync(VaultCrypto._u32(encrypted.ciphertext.length));
        output.writeFromSync(encrypted.ciphertext);
        output.writeFromSync(encrypted.tag);
        remaining -= toRead;
        index++;
      }
    } finally {
      input.closeSync();
      output.closeSync();
    }
  }

  @override
  Future<void> decryptChunks({
    required String containerPath,
    required String outputPath,
    required Uint8List fileKey,
    required Uint8List headerHash,
    required int plaintextLength,
    required int chunkSize,
    required int chunkOffset,
  }) async {
    final input = File(containerPath).openSync(mode: FileMode.read);
    final output = File(outputPath).openSync(mode: FileMode.write);
    try {
      input.setPositionSync(chunkOffset);
      VaultCrypto._processChunksRaw(
        input: input,
        output: output,
        fileKey: fileKey,
        headerHash: headerHash,
        plaintextLength: plaintextLength,
        chunkSize: chunkSize,
      );
    } catch (_) {
      try {
        output.closeSync();
      } catch (_) {
        // Already closed.
      }
      try {
        File(outputPath).deleteSync();
      } catch (_) {
        // Best-effort cleanup.
      }
      rethrow;
    } finally {
      input.closeSync();
      try {
        output.closeSync();
      } catch (_) {
        // Already closed.
      }
    }
  }

  @override
  Future<void> verifyChunks({
    required String containerPath,
    required Uint8List fileKey,
    required Uint8List headerHash,
    required int plaintextLength,
    required int chunkSize,
    required int chunkOffset,
  }) async {
    final input = File(containerPath).openSync(mode: FileMode.read);
    try {
      input.setPositionSync(chunkOffset);
      VaultCrypto._processChunksRaw(
        input: input,
        output: null,
        fileKey: fileKey,
        headerHash: headerHash,
        plaintextLength: plaintextLength,
        chunkSize: chunkSize,
      );
    } finally {
      input.closeSync();
    }
  }
}

class _KeySlot {
  const _KeySlot({
    required this.type,
    required this.nonce,
    required this.ephemeralPublic,
    required this.wrappedKey,
  });

  final int type;
  final Uint8List nonce;
  final Uint8List ephemeralPublic;
  final Uint8List wrappedKey;

  Uint8List toBytes() {
    return Uint8List.fromList([
      type,
      ...nonce,
      ...ephemeralPublic,
      ...wrappedKey,
    ]);
  }
}

class _ContainerHeader {
  const _ContainerHeader({
    required this.prefix,
    required this.slots,
    required this.metadataAad,
    required this.metaNonce,
    required this.metaCiphertext,
    required this.metaTag,
    required this.headerHash,
    required this.plaintextLength,
    required this.chunkSize,
  });

  final Uint8List prefix;
  final List<_KeySlot> slots;
  final Uint8List metadataAad;
  final Uint8List metaNonce;
  final Uint8List metaCiphertext;
  final Uint8List metaTag;
  final List<int> headerHash;
  final int plaintextLength;
  final int chunkSize;
}
