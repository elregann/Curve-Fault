import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Current on-disk version of the protected master-seed record.
///
/// Bump this when the record layout or the KDF contract changes. Records with a
/// different version are rejected instead of being guessed at.
const int seedRecordVersion = 2;

/// Parameters for the Argon2id passphrase KDF.
///
/// Argon2id is memory-hard: every guess must fill [memoryKiB] of memory, which
/// removes the GPU/ASIC advantage that PBKDF2 has. The defaults follow the
/// OWASP Password Storage Cheat Sheet minimum for Argon2id.
class Argon2idParams {
  const Argon2idParams({
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
  });

  /// Argon2 version 1.3, the version standardised by RFC 9106.
  static const int version = Argon2Parameters.ARGON2_VERSION_13;

  /// OWASP minimum for Argon2id: 19 MiB, 2 passes, 1 lane.
  static const Argon2idParams standard = Argon2idParams(
    memoryKiB: 19 * 1024,
    iterations: 2,
    parallelism: 1,
  );

  /// Memory cost in kibibytes.
  final int memoryKiB;

  /// Number of passes over the memory blocks.
  final int iterations;

  /// Number of lanes. Kept at 1 because Dart does not run lanes in parallel.
  final int parallelism;

  /// Rejects parameters that are unsafe or outside the supported range.
  void validate() {
    if (parallelism < 1 || parallelism > 4) {
      throw ArgumentError.value(
        parallelism,
        'parallelism',
        'Argon2id parallelism must be between 1 and 4',
      );
    }
    if (memoryKiB < 8 * 1024 || memoryKiB > 1024 * 1024) {
      throw ArgumentError.value(
        memoryKiB,
        'memoryKiB',
        'Argon2id memory must be between 8 MiB and 1 GiB',
      );
    }
    if (iterations < 1 || iterations > 16) {
      throw ArgumentError.value(
        iterations,
        'iterations',
        'Argon2id iterations must be between 1 and 16',
      );
    }
  }

  Map<String, Object> toJson() {
    return {'m': memoryKiB, 't': iterations, 'p': parallelism};
  }

  factory Argon2idParams.fromJson(Map<String, dynamic> json) {
    final memory = json['m'];
    final passes = json['t'];
    final lanes = json['p'];
    if (memory is! int || passes is! int || lanes is! int) {
      throw const FormatException('Invalid Argon2id parameters');
    }
    final params = Argon2idParams(
      memoryKiB: memory,
      iterations: passes,
      parallelism: lanes,
    )..validate();
    return params;
  }

  @override
  bool operator ==(Object other) {
    return other is Argon2idParams &&
        other.memoryKiB == memoryKiB &&
        other.iterations == iterations &&
        other.parallelism == parallelism;
  }

  @override
  int get hashCode => Object.hash(memoryKiB, iterations, parallelism);
}

/// Derives a 32-byte key from [passphrase] with Argon2id.
///
/// The caller is responsible for running this off the UI thread;
/// `SeedService` wraps it in an isolate.
Uint8List deriveArgon2idKey({
  required String passphrase,
  required Uint8List salt,
  required Argon2idParams params,
}) {
  if (salt.length < 8) {
    throw ArgumentError.value(
      salt.length,
      'salt',
      'Salt must be at least 8 bytes',
    );
  }
  params.validate();

  final input = Uint8List.fromList(utf8.encode(passphrase));
  try {
    final generator = Argon2BytesGenerator()
      ..init(
        Argon2Parameters(
          Argon2Parameters.ARGON2_id,
          salt,
          desiredKeyLength: 32,
          iterations: params.iterations,
          memory: params.memoryKiB,
          lanes: params.parallelism,
          version: Argon2idParams.version,
        ),
      );
    final output = Uint8List(32);
    generator.deriveKey(input, 0, output, 0);
    return output;
  } finally {
    input.fillRange(0, input.length, 0);
  }
}

/// Associated data that binds the seed ciphertext to its KDF parameters.
///
/// Without this, an attacker who can edit the stored record could downgrade the
/// parameters (for example to a single pass) and then attack the passphrase
/// with a much cheaper KDF. Changing any bound field makes decryption fail.
Uint8List seedKdfAad(Argon2idParams params) {
  final description =
      'CurveVault-seed-v$seedRecordVersion|argon2id-v${Argon2idParams.version}'
      '|m=${params.memoryKiB}|t=${params.iterations}|p=${params.parallelism}';
  return Uint8List.fromList(utf8.encode(description));
}
