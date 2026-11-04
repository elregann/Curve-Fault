import 'package:local_auth/local_auth.dart';

/// Thin wrapper around [LocalAuthentication] with graceful fallbacks.
///
/// The vault seed itself is never passed to the platform. This service only
/// asks Android to confirm the user's fingerprint or face before the app reads
/// the seed from secure storage.
class BiometricService {
  BiometricService._();

  static final LocalAuthentication _auth = LocalAuthentication();

  /// Whether the device has biometric hardware and at least one enrollment.
  static Future<bool> isAvailable() async {
    try {
      if (!await _auth.canCheckBiometrics) return false;
      final enrolled = await _auth.getAvailableBiometrics();
      return enrolled.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Shows the system biometric prompt. Returns `true` when the user succeeds.
  static Future<bool> authenticate({required String reason}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } on LocalAuthException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
