import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../crypto/curve256189.dart';
import '../crypto/passphrase_kdf.dart';

/// Cryptographic service providing master seed generation, derivation, and secure storage.
class SeedService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// One versioned record holds the wrapped seed and the exact KDF parameters
  /// used to wrap it. Keeping them together makes the format self-describing
  /// and prevents a silent parameter downgrade.
  static const _keyRecord = 'master_seed_record';

  static const _keyTheme = 'app_theme_mode';
  static const _keyBiometricEnabled = 'biometric_unlock_enabled';
  static const _keyBiometricSeed = 'biometric_unlock_seed';

  /// Keys from the old PBKDF2 format. They are deleted on setup/restore; the
  /// current format deliberately has no backward-compatibility path.
  static const _legacyKeys = [
    'master_seed_encrypted',
    'master_seed_salt',
    'master_seed_nonce',
    'master_seed_tag',
    'has_setup',
  ];

  /// Minimum length accepted for a new or changed passphrase.
  ///
  /// Argon2id raises the cost of each guess, but it cannot rescue a low-entropy
  /// passphrase. Twelve characters is a deliberately simple floor; a multi-word
  /// passphrase is better.
  static const int minPassphraseLength = 12;

  /// Checks if a current-format master seed record exists on this device.
  static Future<bool> hasSetup() async {
    return (await _loadRecord()) != null;
  }

  /// Generates cryptographically secure random bytes of the specified [length].
  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }

  /// Derives a 32-byte key from [passphrase] and [salt] with Argon2id.
  ///
  /// Runs in an isolate because Argon2id is intentionally expensive and must
  /// never block the UI thread.
  static Future<Uint8List> _deriveKey(
    String passphrase,
    Uint8List salt,
    Argon2idParams params,
  ) {
    return Isolate.run(
      () =>
          deriveArgon2idKey(passphrase: passphrase, salt: salt, params: params),
    );
  }

  /// Wraps [seed] with a fresh Argon2id-derived key and stores the record.
  static Future<void> _protectSeed({
    required Uint8List seed,
    required String passphrase,
  }) async {
    if (passphrase.length < minPassphraseLength) {
      throw ArgumentError.value(
        passphrase.length,
        'passphrase',
        'Passphrase must be at least $minPassphraseLength characters',
      );
    }

    const params = Argon2idParams.standard;
    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final key = await _deriveKey(passphrase, salt, params);

    try {
      final encrypted = AESGCM.encrypt(
        key: key,
        nonce: nonce,
        plaintext: seed,
        aad: seedKdfAad(params),
      );
      final record = _SeedRecord(
        params: params,
        salt: salt,
        nonce: nonce,
        ciphertext: Uint8List.fromList(encrypted.ciphertext),
        tag: Uint8List.fromList(encrypted.tag),
      );
      await _storage.write(key: _keyRecord, value: jsonEncode(record.toJson()));
      await _clearLegacyRecords();
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  /// Initializes the application for the first time by generating a random
  /// 32-byte master seed and protecting it with [passphrase].
  static Future<Uint8List> setup(String passphrase) async {
    final seed = _randomBytes(32);
    await _protectSeed(seed: seed, passphrase: passphrase);
    await _clearBiometric();
    return seed;
  }

  /// Restores an existing 32-byte master seed and protects it with [passphrase].
  ///
  /// Use this after reinstalling the app so previously locked `.cvlt` files can
  /// be opened again.
  static Future<Uint8List> restore({
    required Uint8List seed,
    required String passphrase,
  }) async {
    if (seed.length != 32) {
      throw ArgumentError.value(
        seed.length,
        'seed',
        'Master seed must be 32 bytes',
      );
    }
    await _protectSeed(seed: seed, passphrase: passphrase);
    await _clearBiometric();
    return Uint8List.fromList(seed);
  }

  /// Decrypts and retrieves the master seed using the provided [passphrase].
  ///
  /// Returns `null` if the passphrase is incorrect or if the stored record is
  /// corrupted, missing, or written in an unsupported format.
  static Future<Uint8List?> getMasterSeed(String passphrase) async {
    final record = await _loadRecord();
    if (record == null) return null;

    final key = await _deriveKey(passphrase, record.salt, record.params);
    try {
      final plaintext = AESGCM.decrypt(
        key: key,
        nonce: record.nonce,
        ciphertext: record.ciphertext,
        tag: record.tag,
        aad: seedKdfAad(record.params),
      );
      if (plaintext == null || plaintext.length != 32) return null;
      return Uint8List.fromList(plaintext);
    } catch (_) {
      return null;
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  /// Updates the vault passphrase by re-wrapping the existing master seed with
  /// a fresh salt and nonce.
  ///
  /// Returns `true` on successful update, or `false` if [currentPassphrase] is
  /// invalid.
  static Future<bool> changePassphrase({
    required String currentPassphrase,
    required String newPassphrase,
  }) async {
    final seed = await getMasterSeed(currentPassphrase);
    if (seed == null) {
      return false;
    }

    try {
      await _protectSeed(seed: seed, passphrase: newPassphrase);
      return true;
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  static Future<_SeedRecord?> _loadRecord() async {
    try {
      final raw = await _storage.read(key: _keyRecord);
      if (raw == null) return null;
      return _SeedRecord.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Future<void> _clearLegacyRecords() async {
    for (final key in _legacyKeys) {
      try {
        await _storage.delete(key: key);
      } catch (_) {
        // Best effort. Stale records are ignored by the current format.
      }
    }
  }

  /// Generates the XEdDSA identity keypair from the specified [masterSeed].
  static Map<String, Uint8List> generateIdentity(Uint8List masterSeed) {
    return XEdDSA.generateKeyPair(masterSeed);
  }

  /// Retrieves the saved theme mode preference ('light' or 'dark').
  static Future<String?> getThemePreference() async {
    return await _storage.read(key: _keyTheme);
  }

  /// Persists the selected theme mode preference.
  static Future<void> setThemePreference(String mode) async {
    await _storage.write(key: _keyTheme, value: mode);
  }

  /// Whether biometric unlock has been enabled by the user.
  static Future<bool> isBiometricEnabled() async {
    try {
      return (await _storage.read(key: _keyBiometricEnabled)) == 'true';
    } catch (_) {
      return false;
    }
  }

  /// Stores the master seed for biometric unlock.
  ///
  /// The seed stays inside the platform-encrypted secure storage. Callers must
  /// authenticate the user with biometrics before reading it back.
  static Future<void> enableBiometric(Uint8List seed) async {
    if (seed.length != 32) {
      throw ArgumentError.value(
        seed.length,
        'seed',
        'Master seed must be 32 bytes',
      );
    }
    await _storage.write(key: _keyBiometricSeed, value: base64Encode(seed));
    await _storage.write(key: _keyBiometricEnabled, value: 'true');
  }

  /// Disables biometric unlock and removes the stored seed.
  static Future<void> disableBiometric() async {
    await _storage.delete(key: _keyBiometricSeed);
    await _storage.write(key: _keyBiometricEnabled, value: 'false');
  }

  /// Returns the stored master seed for biometric unlock, if present.
  static Future<Uint8List?> getBiometricSeed() async {
    try {
      final value = await _storage.read(key: _keyBiometricSeed);
      if (value == null) return null;
      final bytes = base64Decode(value);
      if (bytes.length != 32) return null;
      return Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _clearBiometric() async {
    await _storage.delete(key: _keyBiometricSeed);
    await _storage.delete(key: _keyBiometricEnabled);
  }

  /// Clears all encrypted credentials, keys, and setup flags from device storage.
  static Future<void> wipe() async {
    await _storage.deleteAll();
  }
}

/// Serialized form of the protected master seed.
///
/// ```json
/// {
///   "v": 2,
///   "kdf": "argon2id",
///   "kdfParams": {"m": 19456, "t": 2, "p": 1},
///   "salt": "<base64>",
///   "nonce": "<base64>",
///   "ct": "<base64>",
///   "tag": "<base64>"
/// }
/// ```
class _SeedRecord {
  const _SeedRecord({
    required this.params,
    required this.salt,
    required this.nonce,
    required this.ciphertext,
    required this.tag,
  });

  final Argon2idParams params;
  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List tag;

  Map<String, Object> toJson() {
    return {
      'v': seedRecordVersion,
      'kdf': 'argon2id',
      'kdfParams': params.toJson(),
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'ct': base64Encode(ciphertext),
      'tag': base64Encode(tag),
    };
  }

  static _SeedRecord? fromJson(Object? value) {
    if (value is! Map) return null;
    if (value['v'] != seedRecordVersion) return null;
    if (value['kdf'] != 'argon2id') return null;

    final paramsJson = value['kdfParams'];
    final saltB64 = value['salt'];
    final nonceB64 = value['nonce'];
    final ciphertextB64 = value['ct'];
    final tagB64 = value['tag'];
    if (paramsJson is! Map ||
        saltB64 is! String ||
        nonceB64 is! String ||
        ciphertextB64 is! String ||
        tagB64 is! String) {
      return null;
    }

    final salt = base64Decode(saltB64);
    final nonce = base64Decode(nonceB64);
    final ciphertext = base64Decode(ciphertextB64);
    final tag = base64Decode(tagB64);
    if (salt.length != 16 ||
        nonce.length != 12 ||
        ciphertext.length != 32 ||
        tag.length != 16) {
      return null;
    }

    final params = Argon2idParams.fromJson(
      Map<String, dynamic>.from(paramsJson),
    );

    return _SeedRecord(
      params: params,
      salt: Uint8List.fromList(salt),
      nonce: Uint8List.fromList(nonce),
      ciphertext: Uint8List.fromList(ciphertext),
      tag: Uint8List.fromList(tag),
    );
  }
}
