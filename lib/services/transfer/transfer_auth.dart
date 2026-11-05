import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../../crypto/curve256189.dart';
import '../../models/transfer_manifest.dart';

/// Signatures used to bind a transfer to the two Curve256189 identities.
///
/// The offer QR itself stays unsigned so it fits in a QR code. Instead the
/// sender signs an `auth` message and the receiver signs a proof of possession
/// immediately after the QR handshake. The sender only sends file bytes after
/// the proof verifies, so a stolen offer cannot be answered by a third party.
class TransferAuth {
  TransferAuth._();

  static const String _authDomain = 'CurveVault-transfer-auth-v1';
  static const String _popDomain = 'CurveVault-transfer-pop-v1';
  static const String _manifestDomain = 'CurveVault-transfer-manifest-v1';

  static Uint8List authMessage({
    required String sessionId,
    required String senderPublicKey,
    required String recipientPublicKey,
  }) {
    return Uint8List.fromList(
      utf8.encode(
        '$_authDomain|$sessionId|$senderPublicKey|$recipientPublicKey',
      ),
    );
  }

  static Uint8List popMessage({
    required String sessionId,
    required String recipientPublicKey,
    required String senderPublicKey,
  }) {
    return Uint8List.fromList(
      utf8.encode(
        '$_popDomain|$sessionId|$recipientPublicKey|$senderPublicKey',
      ),
    );
  }

  static Uint8List manifestMessage(TransferManifest manifest) {
    return Uint8List.fromList([
      ...utf8.encode(_manifestDomain),
      ...manifest.canonicalBytes(),
    ]);
  }

  static Uint8List signSync({
    required Uint8List message,
    required Uint8List seed,
  }) {
    return XEdDSA.sign(message, seed);
  }

  static bool verifySync({
    required Uint8List message,
    required Uint8List signature,
    required Uint8List publicKey,
  }) {
    return XEdDSA.verify(message, signature, publicKey);
  }

  static Future<Uint8List> sign({
    required Uint8List message,
    required Uint8List seed,
  }) {
    return Isolate.run(() => XEdDSA.sign(message, seed));
  }

  static Future<bool> verify({
    required Uint8List message,
    required Uint8List signature,
    required Uint8List publicKey,
  }) {
    return Isolate.run(() => XEdDSA.verify(message, signature, publicKey));
  }

  static Future<String> signAuth({
    required Uint8List seed,
    required String sessionId,
    required String senderPublicKey,
    required String recipientPublicKey,
  }) async {
    final signature = await sign(
      message: authMessage(
        sessionId: sessionId,
        senderPublicKey: senderPublicKey,
        recipientPublicKey: recipientPublicKey,
      ),
      seed: seed,
    );
    return encodeSignature(signature);
  }

  static Future<bool> verifyAuth({
    required String signature,
    required String sessionId,
    required String senderPublicKey,
    required String recipientPublicKey,
  }) async {
    final bytes = decodeSignature(signature);
    final publicKey = publicKeyBytes(senderPublicKey);
    if (bytes == null || publicKey == null) return false;
    return verify(
      message: authMessage(
        sessionId: sessionId,
        senderPublicKey: senderPublicKey,
        recipientPublicKey: recipientPublicKey,
      ),
      signature: bytes,
      publicKey: publicKey,
    );
  }

  static Future<String> signProofOfPossession({
    required Uint8List seed,
    required String sessionId,
    required String recipientPublicKey,
    required String senderPublicKey,
  }) async {
    final signature = await sign(
      message: popMessage(
        sessionId: sessionId,
        recipientPublicKey: recipientPublicKey,
        senderPublicKey: senderPublicKey,
      ),
      seed: seed,
    );
    return encodeSignature(signature);
  }

  static Future<bool> verifyProofOfPossession({
    required String signature,
    required String sessionId,
    required String recipientPublicKey,
    required String senderPublicKey,
  }) async {
    final bytes = decodeSignature(signature);
    final publicKey = publicKeyBytes(recipientPublicKey);
    if (bytes == null || publicKey == null) return false;
    return verify(
      message: popMessage(
        sessionId: sessionId,
        recipientPublicKey: recipientPublicKey,
        senderPublicKey: senderPublicKey,
      ),
      signature: bytes,
      publicKey: publicKey,
    );
  }

  static Future<String> signManifest({
    required TransferManifest manifest,
    required Uint8List seed,
  }) async {
    final signature = await sign(
      message: manifestMessage(manifest),
      seed: seed,
    );
    return encodeSignature(signature);
  }

  static Future<bool> verifyManifest({
    required TransferManifest manifest,
    required String signature,
  }) async {
    final bytes = decodeSignature(signature);
    final publicKey = publicKeyBytes(manifest.senderPublicKey);
    if (bytes == null || publicKey == null) return false;
    return verify(
      message: manifestMessage(manifest),
      signature: bytes,
      publicKey: publicKey,
    );
  }

  static String encodeSignature(Uint8List signature) {
    return base64Url.encode(signature).replaceAll('=', '');
  }

  static Uint8List? decodeSignature(String encoded) {
    try {
      final bytes = base64Url.decode(base64Url.normalize(encoded));
      return bytes.length == XEdDSA.signatureLength
          ? Uint8List.fromList(bytes)
          : null;
    } catch (_) {
      return null;
    }
  }

  static Uint8List? publicKeyBytes(String hex) {
    if (hex.length != 64 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
      return null;
    }
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  static String hexOf(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Comparison that does not stop at the first different byte.
  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  static bool constantTimeEqualsHex(String a, String b) {
    return constantTimeEquals(
      utf8.encode(a.toLowerCase()),
      utf8.encode(b.toLowerCase()),
    );
  }
}
