import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/transfer_session.dart';

/// Thrown when a scanned QR payload is malformed, oversized, or unsupported.
class TransferQrException implements Exception {
  const TransferQrException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One compact signaling payload carried inside a QR code.
///
/// Wire format: `cvlt1.` + base64url(gzip(json)). The gzip step keeps the SDP
/// small enough for a single QR code and the strict decoder rejects anything
/// that does not match the expected shape.
class TransferQrPayload {
  const TransferQrPayload({
    required this.role,
    required this.sessionId,
    required this.fromPublicKey,
    required this.expiresAt,
    required this.sdp,
  });

  static const String prefix = 'cvlt1.';
  static const int version = 1;

  /// A QR code at error-correction level L holds at most 2953 bytes.
  static const int maxEncodedLength = 2900;
  static const int maxCompressedBytes = 8192;
  static const int maxJsonBytes = 32 * 1024;
  static const int maxSdpLength = 16 * 1024;

  final TransferQrRole role;
  final String sessionId;
  final String fromPublicKey;

  /// Unix timestamp in seconds.
  final int expiresAt;

  final String sdp;

  bool isExpired([DateTime? now]) {
    final current = now ?? DateTime.now();
    return current.millisecondsSinceEpoch ~/ 1000 >= expiresAt;
  }

  String encode() {
    final normalizedSession = sessionId.toLowerCase();
    final normalizedKey = fromPublicKey.toLowerCase();
    if (!_isHex(normalizedSession, 32)) {
      throw const TransferQrException('Invalid session id');
    }
    if (!_isHex(normalizedKey, 64)) {
      throw const TransferQrException('Invalid public key');
    }
    if (expiresAt <= 0) {
      throw const TransferQrException('Invalid expiry');
    }
    _validateSdp(sdp);

    final payload = <String, dynamic>{
      'v': version,
      't': role == TransferQrRole.offer ? 'offer' : 'answer',
      'sid': normalizedSession,
      'from': normalizedKey,
      'exp': expiresAt,
      'sdp': sdp,
    };
    final compressed = gzip.encode(utf8.encode(jsonEncode(payload)));
    if (compressed.length > maxCompressedBytes) {
      throw const TransferQrException('Connection data is too large for a QR');
    }
    final encoded = '$prefix${base64Url.encode(compressed).replaceAll('=', '')}';
    if (encoded.length > maxEncodedLength) {
      throw const TransferQrException(
        'Connection data is too large for a QR. Try a different network.',
      );
    }
    return encoded;
  }

  static TransferQrPayload decode(String raw) {
    final text = raw.trim();
    if (text.isEmpty || text.length > maxEncodedLength) {
      throw const TransferQrException('QR code is not a CurveVault code');
    }
    if (!text.startsWith(prefix)) {
      throw const TransferQrException('QR code is not a CurveVault code');
    }

    final encoded = text.substring(prefix.length);
    final List<int> compressed;
    try {
      compressed = base64Url.decode(base64Url.normalize(encoded));
    } catch (_) {
      throw const TransferQrException('QR code is damaged or unsupported');
    }
    if (compressed.isEmpty || compressed.length > maxCompressedBytes) {
      throw const TransferQrException('QR code is not a CurveVault code');
    }

    final Uint8List jsonBytes;
    try {
      final sink = _CappedByteSink(maxJsonBytes);
      final decoder = gzip.decoder.startChunkedConversion(sink);
      decoder.add(compressed);
      decoder.close();
      jsonBytes = sink.takeBytes();
    } on FormatException {
      throw const TransferQrException('QR code is damaged or unsupported');
    } on TransferQrException {
      rethrow;
    } catch (_) {
      throw const TransferQrException('QR code is damaged or unsupported');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(jsonBytes));
    } catch (_) {
      throw const TransferQrException('QR code is damaged or unsupported');
    }
    if (decoded is! Map) {
      throw const TransferQrException('QR code is damaged or unsupported');
    }
    final json = Map<String, dynamic>.from(decoded);

    if (_asInt(json['v']) != version) {
      throw const TransferQrException('Unsupported QR code version');
    }

    final type = json['t'];
    final TransferQrRole role;
    if (type == 'offer') {
      role = TransferQrRole.offer;
    } else if (type == 'answer') {
      role = TransferQrRole.answer;
    } else {
      throw const TransferQrException('Unknown QR code type');
    }

    final sessionId = _hex(json['sid'], 32);
    final fromPublicKey = _hex(json['from'], 64);
    final expiresAt = _asInt(json['exp']);
    if (expiresAt <= 0) {
      throw const TransferQrException('Invalid QR expiry');
    }

    final sdp = json['sdp'];
    if (sdp is! String || sdp.isEmpty || sdp.length > maxSdpLength) {
      throw const TransferQrException('Invalid connection data');
    }
    _validateSdp(sdp);

    return TransferQrPayload(
      role: role,
      sessionId: sessionId,
      fromPublicKey: fromPublicKey,
      expiresAt: expiresAt,
      sdp: sdp,
    );
  }

  static void _validateSdp(String sdp) {
    if (sdp.length > maxSdpLength ||
        !sdp.startsWith('v=0') ||
        !sdp.contains('\nm=application ') ||
        !sdp.contains('\na=ice-ufrag:') ||
        sdp.contains('\x00')) {
      throw const TransferQrException('Invalid connection data');
    }
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    throw const TransferQrException('Invalid QR code');
  }

  static String _hex(Object? value, int length) {
    if (value is! String) {
      throw const TransferQrException('Invalid QR code');
    }
    final normalized = value.toLowerCase();
    if (!_isHex(normalized, length)) {
      throw const TransferQrException('Invalid QR code');
    }
    return normalized;
  }

  static bool _isHex(String value, int length) {
    return value.length == length &&
        RegExp('^[0-9a-f]{$length}\$').hasMatch(value);
  }
}

/// A [Sink] that refuses decompressed QR payloads above [limit] bytes.
class _CappedByteSink implements Sink<List<int>> {
  _CappedByteSink(this.limit);

  final int limit;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _length = 0;
  bool _closed = false;

  @override
  void add(List<int> data) {
    _length += data.length;
    if (_length > limit) {
      throw const TransferQrException('QR payload is too large');
    }
    _builder.add(data);
  }

  @override
  void close() {
    _closed = true;
  }

  Uint8List takeBytes() {
    if (!_closed) {
      throw const TransferQrException('QR payload is incomplete');
    }
    return _builder.takeBytes();
  }
}
