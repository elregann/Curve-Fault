import 'package:curve_fault/services/seed_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('setup wraps the seed and rejects a wrong passphrase', () async {
    final seed = await SeedService.setup('correct horse battery staple');

    expect(seed.length, 32);
    expect(await SeedService.hasSetup(), isTrue);
    expect(
      await SeedService.getMasterSeed('correct horse battery staple'),
      equals(seed),
    );
    expect(await SeedService.getMasterSeed('wrong passphrase'), isNull);
  });

  test('rejects short passphrases', () async {
    expect(() => SeedService.setup('short'), throwsArgumentError);
  });

  test('changePassphrase rotates the wrapping key', () async {
    final seed = await SeedService.setup('correct horse battery staple');

    expect(
      await SeedService.changePassphrase(
        currentPassphrase: 'wrong passphrase',
        newPassphrase: 'another long passphrase',
      ),
      isFalse,
    );

    expect(
      await SeedService.changePassphrase(
        currentPassphrase: 'correct horse battery staple',
        newPassphrase: 'another long passphrase',
      ),
      isTrue,
    );
    expect(
      await SeedService.getMasterSeed('correct horse battery staple'),
      isNull,
    );
    expect(
      await SeedService.getMasterSeed('another long passphrase'),
      equals(seed),
    );
  });
}
