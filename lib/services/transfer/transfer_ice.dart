/// ICE server configuration for the peer-to-peer transfer.
///
/// Public STUN servers are always included. A TURN relay is required when the
/// two devices cannot reach each other directly (mobile data, strict NAT, or
/// corporate Wi-Fi). Supply a private TURN service at build time:
///
/// ```bash
/// flutter build apk --release \
///   --dart-define=CURVE_TURN_URLS="turn:turn.example.com:3478?transport=udp,turn:turn.example.com:5349?transport=tcp" \
///   --dart-define=CURVE_TURN_USERNAME=curve \
///   --dart-define=CURVE_TURN_CREDENTIAL=secret
/// ```
///
/// When no complete custom configuration is supplied, the shared OpenRelay
/// service is used as a best-effort fallback. It is rate-limited and may be
/// unavailable, so it is not a substitute for a private TURN server.
class TransferIceConfig {
  TransferIceConfig._();

  static const String _envUrls = String.fromEnvironment('CURVE_TURN_URLS');
  static const String _envUsername = String.fromEnvironment(
    'CURVE_TURN_USERNAME',
  );
  static const String _envCredential = String.fromEnvironment(
    'CURVE_TURN_CREDENTIAL',
  );

  static const List<String> _stunUrls = <String>[
    'stun:stun.l.google.com:19302',
    'stun:stun1.l.google.com:19302',
    'stun:stun.cloudflare.com:3478',
  ];

  static const List<String> _fallbackTurnUrls = <String>[
    'turn:openrelay.metered.ca:80',
    'turn:openrelay.metered.ca:443',
    'turn:openrelay.metered.ca:443?transport=tcp',
  ];

  /// Builds the `iceServers` list passed to `createPeerConnection`.
  ///
  /// The optional arguments exist so tests can exercise the parser without
  /// recompiling. They default to the `--dart-define` values.
  static List<Map<String, dynamic>> build({
    String urls = _envUrls,
    String username = _envUsername,
    String credential = _envCredential,
  }) {
    final servers = <Map<String, dynamic>>[
      for (final url in _stunUrls) <String, dynamic>{'urls': url},
    ];

    final customUrls = _parseTurnUrls(urls);
    final customUsername = username.trim();
    final customCredential = credential.trim();

    if (customUrls.isNotEmpty &&
        customUsername.isNotEmpty &&
        customCredential.isNotEmpty) {
      servers.add(<String, dynamic>{
        'urls': customUrls.length == 1 ? customUrls.single : customUrls,
        'username': customUsername,
        'credential': customCredential,
      });
    } else {
      servers.add(<String, dynamic>{
        'urls': List<String>.of(_fallbackTurnUrls),
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      });
    }

    return servers;
  }

  static List<String> _parseTurnUrls(String raw) {
    return raw
        .split(RegExp(r'[,\s]+'))
        .map((url) => url.trim())
        .where((url) => url.startsWith('turn:') || url.startsWith('turns:'))
        .toList(growable: false);
  }
}
