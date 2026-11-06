import 'package:curve_fault/services/transfer/transfer_ice.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TransferIceConfig.build', () {
    test('always includes the public STUN servers', () {
      final servers = TransferIceConfig.build(
        urls: '',
        username: '',
        credential: '',
      );

      final stunUrls = servers
          .expand(_urls)
          .where((url) => url.startsWith('stun:'))
          .toList();

      expect(
        stunUrls,
        containsAll(<String>[
          'stun:stun.l.google.com:19302',
          'stun:stun1.l.google.com:19302',
          'stun:stun.cloudflare.com:3478',
        ]),
      );
    });

    test('falls back to OpenRelay when no custom TURN is configured', () {
      final servers = TransferIceConfig.build(
        urls: '',
        username: '',
        credential: '',
      );

      final turn = servers.singleWhere(
        (server) => server['username'] == 'openrelayproject',
      );
      expect(
        _urls(turn),
        contains('turn:openrelay.metered.ca:443?transport=tcp'),
      );
    });

    test('uses a custom TURN server when every value is present', () {
      final servers = TransferIceConfig.build(
        urls:
            'turn:turn.example.com:3478?transport=udp, '
            'turns:turn.example.com:5349?transport=tcp',
        username: 'curve',
        credential: 'secret',
      );

      final turn = servers.singleWhere(
        (server) => server['username'] == 'curve',
      );
      expect(turn['credential'], 'secret');
      expect(_urls(turn), <String>[
        'turn:turn.example.com:3478?transport=udp',
        'turns:turn.example.com:5349?transport=tcp',
      ]);
      expect(
        servers.any((server) => server['username'] == 'openrelayproject'),
        isFalse,
      );
    });

    test('passes a single custom URL as a string', () {
      final servers = TransferIceConfig.build(
        urls: 'turn:turn.example.com:3478',
        username: 'curve',
        credential: 'secret',
      );

      final turn = servers.singleWhere(
        (server) => server['username'] == 'curve',
      );
      expect(turn['urls'], 'turn:turn.example.com:3478');
    });

    test('falls back when the custom TURN configuration is incomplete', () {
      final servers = TransferIceConfig.build(
        urls: 'turn:turn.example.com:3478',
        username: '',
        credential: '',
      );

      expect(servers.any((server) => server['username'] == 'curve'), isFalse);
      expect(
        servers.any((server) => server['username'] == 'openrelayproject'),
        isTrue,
      );
    });

    test('ignores URLs that are not TURN endpoints', () {
      final servers = TransferIceConfig.build(
        urls: 'stun:stun.example.com:3478, https://nope.example.com',
        username: 'curve',
        credential: 'secret',
      );

      expect(servers.any((server) => server['username'] == 'curve'), isFalse);
      expect(
        servers.any((server) => server['username'] == 'openrelayproject'),
        isTrue,
      );
    });
  });
}

List<String> _urls(Map<String, dynamic> server) {
  final value = server['urls'];
  if (value is String) return <String>[value];
  if (value is List) return value.cast<String>();
  return const <String>[];
}
