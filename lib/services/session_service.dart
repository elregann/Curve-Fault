import 'dart:typed_data';
import '../services/seed_service.dart';

/// In-memory session manager that retains cryptographic materials during runtime.
///
/// Ensures master seed and identity keypairs are accessible across pages
/// while avoiding persistent exposure in plain storage.
class SessionService {
  static Uint8List? _masterSeed;
  static Map<String, Uint8List>? _identity;

  /// Whether the user has unlocked the vault for the current session.
  static bool get isUnlocked => _masterSeed != null;

  /// The active master seed bytes for this session, if unlocked.
  static Uint8List? get masterSeed => _masterSeed;

  /// The XEdDSA 32-byte public key derived from the master seed.
  static Uint8List? get publicKey => _identity?['publicKey'];

  /// Hex-encoded representation of the public key.
  static String? get publicKeyHex {
    final pk = publicKey;
    if (pk == null) return null;
    return pk.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Establishes the active session using the provided [seed].
  static void setSession(Uint8List seed) {
    _masterSeed = Uint8List.fromList(seed);
    _identity = SeedService.generateIdentity(_masterSeed!);
  }

  /// Wipes all in-memory cryptographic materials for the current session.
  static void clearSession() {
    if (_masterSeed != null) {
      _masterSeed!.fillRange(0, _masterSeed!.length, 0);
      _masterSeed = null;
    }
    _identity = null;
  }
}

