import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/transfer_manifest.dart';

/// A received container plus the signed description that arrived with it.
class ReceivedBundle {
  const ReceivedBundle({
    required this.container,
    required this.manifest,
    required this.signature,
    required this.receivedAt,
  });

  final File container;
  final TransferManifest manifest;
  final String signature;
  final int receivedAt;
}

/// App-private locations used by the peer transfer feature.
///
/// Received containers live under `CurveVault/received/`. A signed sidecar is
/// written next to them before the file is acknowledged, so an interrupted
/// import can be finished after the next unlock.
class TransferStorage {
  TransferStorage._();

  static final TransferStorage instance = TransferStorage._();

  static const String _sidecarSuffix = '.manifest.json';
  static const int sidecarVersion = 1;

  Future<Directory> _baseDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/CurveVault');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<Directory> outgoingDir() async {
    final dir = Directory('${(await _baseDir()).path}/outgoing');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<Directory> receivedDir() async {
    final dir = Directory('${(await _baseDir()).path}/received');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<Directory> tempDir() async {
    final cache = await getTemporaryDirectory();
    final dir = Directory('${cache.path}/curve_vault_transfer');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<String> newOutgoingPath() async {
    final dir = await outgoingDir();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return '${dir.path}/share_$stamp.cvlt';
  }

  Future<File> newIncomingTemp() async {
    final dir = await tempDir();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return File('${dir.path}/incoming_$stamp.cvlt');
  }

  File sidecarFor(File container) {
    return File('${container.path}$_sidecarSuffix');
  }

  Future<File> commitReceived({
    required File temporary,
    required TransferManifest manifest,
  }) async {
    final dir = await receivedDir();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final shortSession = manifest.sessionId.substring(0, 8);
    final target = File('${dir.path}/received_${stamp}_$shortSession.cvlt');
    final temporarySidecar = sidecarFor(temporary);
    try {
      await temporary.rename(target.path);
    } on FileSystemException {
      await temporary.copy(target.path);
      await _safeDelete(temporary);
    }
    // The sidecar is written next to the temporary file first, so moving both
    // here leaves no committed container without its signed manifest.
    if (temporarySidecar.existsSync()) {
      try {
        await temporarySidecar.rename(sidecarFor(target).path);
      } on FileSystemException {
        await temporarySidecar.copy(sidecarFor(target).path);
        await _safeDelete(temporarySidecar);
      }
    }
    return target;
  }

  Future<void> writeSidecar({
    required File container,
    required TransferManifest manifest,
    required String signature,
    required int receivedAt,
  }) async {
    final payload = <String, dynamic>{
      'v': sidecarVersion,
      'manifest': manifest.toJson(),
      'signature': signature,
      'receivedAt': receivedAt,
    };
    final file = sidecarFor(container);
    await file.writeAsString(jsonEncode(payload), flush: true);
  }

  Future<List<ReceivedBundle>> listPendingBundles() async {
    final dir = await receivedDir();
    final bundles = <ReceivedBundle>[];
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.cvlt')) {
        continue;
      }
      final sidecar = sidecarFor(entity);
      if (!sidecar.existsSync()) continue;
      try {
        final decoded = jsonDecode(await sidecar.readAsString());
        if (decoded is! Map) continue;
        final map = Map<String, dynamic>.from(decoded);
        if ((map['v'] as num?)?.toInt() != sidecarVersion) continue;
        final rawManifest = map['manifest'];
        if (rawManifest is! Map) continue;
        final manifest = TransferManifest.fromJson(
          Map<String, dynamic>.from(rawManifest),
        );
        final signature = map['signature'];
        final receivedAt = (map['receivedAt'] as num?)?.toInt();
        if (signature is! String || signature.isEmpty) continue;
        if (receivedAt == null || receivedAt <= 0) continue;
        bundles.add(
          ReceivedBundle(
            container: entity,
            manifest: manifest,
            signature: signature,
            receivedAt: receivedAt,
          ),
        );
      } catch (_) {
        // A damaged sidecar is left in place for diagnostics; import skips it.
      }
    }
    return bundles;
  }

  Future<File> writeQrPng(Uint8List bytes) async {
    final dir = await tempDir();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final file = File('${dir.path}/curvevault_qr_$stamp.png');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<String> hashFileHex(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<void> deleteSidecar(File container) async {
    await _safeDelete(sidecarFor(container));
  }

  Future<void> cleanupOutgoing() async {
    final dir = await outgoingDir();
    for (final entity in dir.listSync(followLinks: false)) {
      await _safeDelete(entity);
    }
  }

  Future<void> cleanupTemporary() async {
    final dir = await tempDir();
    for (final entity in dir.listSync(followLinks: false)) {
      await _safeDelete(entity);
    }
  }

  void scheduleCleanup(File file) {
    Future<void>.delayed(const Duration(minutes: 10), () {
      _safeDelete(file);
    });
  }

  Future<void> _safeDelete(FileSystemEntity entity) async {
    try {
      if (entity.existsSync()) {
        await entity.delete(recursive: true);
      }
    } catch (_) {
      // Best-effort cleanup only.
    }
  }
}
