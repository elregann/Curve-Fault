import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:curve_fault/services/session_service.dart';
import 'package:curve_fault/services/seed_service.dart';

void main() {
  test('SessionService manages master seed and generates public key', () {
    final dummySeed = Uint8List.fromList(List.generate(32, (i) => i));
    SessionService.setSession(dummySeed);

    expect(SessionService.isUnlocked, isTrue);
    expect(SessionService.masterSeed, equals(dummySeed));
    expect(SessionService.publicKey, isNotNull);
    expect(SessionService.publicKeyHex, isNotNull);
    expect(SessionService.publicKeyHex!.length, equals(64)); // 32 bytes hex = 64 hex chars

    SessionService.clearSession();
    expect(SessionService.isUnlocked, isFalse);
    expect(SessionService.masterSeed, isNull);
    expect(SessionService.publicKey, isNull);
    expect(SessionService.publicKeyHex, isNull);
  });

  test('SeedService generates valid identity keypair from seed', () {
    final seed = Uint8List(32)..fillRange(0, 32, 7);
    final keyPair = SeedService.generateIdentity(seed);

    expect(keyPair.containsKey('privateKey'), isTrue);
    expect(keyPair.containsKey('publicKey'), isTrue);
    expect(keyPair['publicKey']!.length, equals(32));
  });
}

