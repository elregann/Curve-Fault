import 'dart:convert';
import 'dart:typed_data';

/// Signed description of the encrypted container sent over a transfer.
///
/// The manifest travels on the control channel before any file bytes. It binds
/// the session, both identities, and the exact container the receiver must
/// write, so a tampered or swapped file is rejected.
class TransferManifest {
  const TransferManifest({
    required this.sessionId,
    required this.name,
    required this.mime,
    required this.size,
    required this.containerSize,
    required this.sha256,
    required this.senderPublicKey,
    required this.recipientPublicKey,
    required this.createdAt,
  });

  static const int version = 1;

  /// Upper bound accepted from the network. Kept deliberately generous for
  /// vault files while still preventing unbounded writes.
  static const int maxContainerBytes = 8 * 1024 * 1024 * 1024;

  static const int maxPlaintextBytes = 8 * 1024 * 1024 * 1024;

  final String sessionId;
  final String name;
  final String mime;

  /// Plaintext size, used for display only.
  final int size;

  /// Exact number of encrypted container bytes that follow.
  final int containerSize;

  /// Hex-encoded SHA-256 of the encrypted container.
  final String sha256;

  final String senderPublicKey;
  final String recipientPublicKey;
  final int createdAt;

  Map<String, dynamic> toJson() {
    return {
      'v': version,
      'sid': sessionId,
      'name': name,
      'mime': mime,
      'size': size,
      'containerSize': containerSize,
      'sha256': sha256,
      'sender': senderPublicKey,
      'recipient': recipientPublicKey,
      'createdAt': createdAt,
    };
  }

  /// Stable bytes used for signing and verification.
  Uint8List canonicalBytes() {
    return Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
  }

  factory TransferManifest.fromJson(Map<String, dynamic> json) {
    if (_asInt(json['v']) != version) {
      throw const FormatException('Unsupported transfer manifest version');
    }

    final sessionId = _hex(json['sid'], 32, 'sid');
    final name = _name(json['name']);
    final mime = _mime(json['mime']);
    final size = _size(json['size'], 'size');
    final containerSize = _size(json['containerSize'], 'containerSize');
    final sha256 = _hex(json['sha256'], 64, 'sha256');
    final sender = _hex(json['sender'], 64, 'sender');
    final recipient = _hex(json['recipient'], 64, 'recipient');
    final createdAt = _asInt(json['createdAt']);
    if (createdAt <= 0) {
      throw const FormatException('Invalid manifest timestamp');
    }

    if (containerSize > maxContainerBytes) {
      throw const FormatException('Transferred container is too large');
    }
    if (size > maxPlaintextBytes) {
      throw const FormatException('Transferred file is too large');
    }

    return TransferManifest(
      sessionId: sessionId,
      name: name,
      mime: mime,
      size: size,
      containerSize: containerSize,
      sha256: sha256,
      senderPublicKey: sender,
      recipientPublicKey: recipient,
      createdAt: createdAt,
    );
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    throw const FormatException('Expected an integer');
  }

  static int _size(Object? value, String label) {
    final parsed = _asInt(value);
    if (parsed < 0) {
      throw FormatException('Invalid $label');
    }
    return parsed;
  }

  static String _hex(Object? value, int length, String label) {
    if (value is! String) {
      throw FormatException('Invalid $label');
    }
    final normalized = value.toLowerCase();
    if (!RegExp('^[0-9a-f]{$length}\$').hasMatch(normalized)) {
      throw FormatException('Invalid $label');
    }
    return normalized;
  }

  static String _name(Object? value) {
    if (value is! String) {
      throw const FormatException('Invalid file name');
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        trimmed.length > 255 ||
        trimmed == '.' ||
        trimmed == '..' ||
        trimmed.contains('/') ||
        trimmed.contains('\\') ||
        trimmed.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const FormatException('Invalid file name');
    }
    return trimmed;
  }

  static String _mime(Object? value) {
    if (value is! String) {
      throw const FormatException('Invalid mime type');
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        trimmed.length > 128 ||
        !trimmed.contains('/') ||
        trimmed.contains(RegExp(r'[\s\x00-\x1f\x7f]'))) {
      throw const FormatException('Invalid mime type');
    }
    return trimmed;
  }
}
