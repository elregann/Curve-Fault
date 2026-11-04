import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

import '../crypto/curve256189.dart';

/// Cryptographic service providing master seed generation, derivation, and secure storage.
class SeedService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _keySeed = 'master_seed_encrypted';
  static const _keySalt = 'master_seed_salt';
  static const _keyNonce = 'master_seed_nonce';
  static const _keyTag = 'master_seed_tag';
  static const _keyHasSetup = 'has_setup';
  static const _keyTheme = 'app_theme_mode';
  static const _keyBiometricEnabled = 'biometric_unlock_enabled';
  static const _keyBiometricSeed = 'biometric_unlock_seed';

  /// Number of PBKDF2 iterations balancing mobile hardware performance and security.
  static const int pbkdf2Iterations = 60000;

  /// Checks if the master seed has already been set up on this device.
  static Future<bool> hasSetup() async {
    final value = await _storage.read(key: _keyHasSetup);
    return value == 'true';
  }

  /// Generates cryptographically secure random bytes of the specified [length].
  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }

  /// Derives a 32-byte key from [passphrase] and [salt] using PBKDF2 with HMAC-SHA256.
  ///
  /// Executed in an isolated background thread via [Isolate.run] to prevent
  /// blocking the main UI thread during the 60,000 computation cycles.
  static Future<Uint8List> _deriveKey(String passphrase, Uint8List salt) {
    return Isolate.run(() {
      final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
        ..init(Pbkdf2Parameters(salt, pbkdf2Iterations, 32));

      return derivator.process(Uint8List.fromList(utf8.encode(passphrase)));
    });
  }

  /// Initializes the application for the first time by generating a random 32-byte
  /// master seed and encrypting it with a key derived from [passphrase].
  static Future<Uint8List> setup(String passphrase) async {
    final seed = _randomBytes(32);
    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);

    final key = await _deriveKey(passphrase, salt);

    final result = AESGCM.encrypt(key: key, nonce: nonce, plaintext: seed);

    await _storage.write(key: _keySalt, value: base64Encode(salt));
    await _storage.write(key: _keyNonce, value: base64Encode(nonce));
    await _storage.write(key: _keySeed, value: base64Encode(result.ciphertext));
    await _storage.write(key: _keyTag, value: base64Encode(result.tag));
    await _storage.write(key: _keyHasSetup, value: 'true');
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
    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final key = await _deriveKey(passphrase, salt);
    final result = AESGCM.encrypt(key: key, nonce: nonce, plaintext: seed);

    await _storage.write(key: _keySalt, value: base64Encode(salt));
    await _storage.write(key: _keyNonce, value: base64Encode(nonce));
    await _storage.write(key: _keySeed, value: base64Encode(result.ciphertext));
    await _storage.write(key: _keyTag, value: base64Encode(result.tag));
    await _storage.write(key: _keyHasSetup, value: 'true');
    await _clearBiometric();

    return Uint8List.fromList(seed);
  }

  /// Decrypts and retrieves the master seed using the provided [passphrase].
  ///
  /// Returns `null` if the passphrase is incorrect or if the stored records are corrupted.
  static Future<Uint8List?> getMasterSeed(String passphrase) async {
    final saltB64 = await _storage.read(key: _keySalt);
    final nonceB64 = await _storage.read(key: _keyNonce);
    final cipherB64 = await _storage.read(key: _keySeed);
    final tagB64 = await _storage.read(key: _keyTag);

    if (saltB64 == null ||
        nonceB64 == null ||
        cipherB64 == null ||
        tagB64 == null) {
      return null;
    }

    final salt = base64Decode(saltB64);
    final nonce = base64Decode(nonceB64);
    final ciphertext = base64Decode(cipherB64);
    final tag = base64Decode(tagB64);

    final key = await _deriveKey(passphrase, salt);

    try {
      final plaintext = AESGCM.decrypt(
        key: key,
        nonce: nonce,
        ciphertext: ciphertext,
        tag: tag,
      );
      return plaintext;
    } catch (_) {
      return null;
    }
  }

  /// Updates the vault passphrase by re-encrypting the existing master seed.
  ///
  /// Returns `true` on successful update, or `false` if [currentPassphrase] is invalid.
  static Future<bool> changePassphrase({
    required String currentPassphrase,
    required String newPassphrase,
  }) async {
    final seed = await getMasterSeed(currentPassphrase);
    if (seed == null) {
      return false;
    }

    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final key = await _deriveKey(newPassphrase, salt);

    final result = AESGCM.encrypt(key: key, nonce: nonce, plaintext: seed);

    await _storage.write(key: _keySalt, value: base64Encode(salt));
    await _storage.write(key: _keyNonce, value: base64Encode(nonce));
    await _storage.write(key: _keySeed, value: base64Encode(result.ciphertext));
    await _storage.write(key: _keyTag, value: base64Encode(result.tag));

    return true;
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
