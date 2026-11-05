import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_lock.dart';
import 'vault_crypto.dart';

/// A file or directory selected through Android's Storage Access Framework.
class NativeDocument {
  const NativeDocument({
    required this.uri,
    required this.name,
    required this.mime,
    required this.size,
    required this.relativePath,
    required this.parentUri,
    required this.lastModified,
    required this.isDirectory,
    required this.canWrite,
  });

  final String uri;
  final String name;
  final String mime;
  final int size;
  final String relativePath;
  final String parentUri;
  final int lastModified;
  final bool isDirectory;
  final bool canWrite;

  /// The same document seen through another uri, for example the tree form
  /// that a folder grant covers.
  NativeDocument withLocation({
    required String uri,
    required String relativePath,
  }) {
    return NativeDocument(
      uri: uri,
      name: name,
      mime: mime,
      size: size,
      relativePath: relativePath,
      parentUri: parentUri,
      lastModified: lastModified,
      isDirectory: isDirectory,
      canWrite: canWrite,
    );
  }

  factory NativeDocument.fromMap(Map<dynamic, dynamic> map) {
    return NativeDocument(
      uri: map['uri'] as String,
      name: map['name'] as String? ?? 'Unknown',
      mime: map['mime'] as String? ?? 'application/octet-stream',
      size: (map['size'] as num?)?.toInt() ?? 0,
      relativePath: map['relativePath'] as String? ?? '',
      parentUri: map['parentUri'] as String? ?? '',
      lastModified: (map['lastModified'] as num?)?.toInt() ?? 0,
      isDirectory: map['isDirectory'] as bool? ?? false,
      canWrite: map['canWrite'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'uri': uri,
      'name': name,
      'mime': mime,
      'size': size,
      'relativePath': relativePath,
      'parentUri': parentUri,
      'lastModified': lastModified,
      'isDirectory': isDirectory,
      'canWrite': canWrite,
    };
  }
}

/// Whether any segment of [relativePath] is a hidden file or folder.
bool isHiddenPath(String relativePath) {
  return relativePath.split('/').any((segment) => segment.startsWith('.'));
}

/// Existence, name and size of a single document.
class DocumentStat {
  const DocumentStat({
    required this.exists,
    required this.name,
    required this.size,
  });

  final bool exists;
  final String name;
  final int size;
}

/// Storage document ids for a batch of picked uris, in the order asked.
/// An id is `null` when the real location could not be found.
class DocumentIds {
  const DocumentIds({required this.sdk, required this.ids});

  final int sdk;
  final List<String?> ids;
}

/// Result of replacing a plaintext document with its encrypted container.
class LockedDocument {
  const LockedDocument({
    required this.uri,
    required this.name,
    required this.size,
  });

  final String uri;
  final String name;
  final int size;

  factory LockedDocument.fromMap(Map<dynamic, dynamic> map) {
    return LockedDocument(
      uri: map['uri'] as String,
      name: map['name'] as String? ?? '',
      size: (map['size'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Thin MethodChannel bridge to the native storage and AES-GCM helpers.
class NativeStorage {
  NativeStorage._();

  static const MethodChannel _channel = MethodChannel('curve_fault/storage');

  /// Appended by the native side when a failed lock could not be rolled back.
  static const String recoveryMarker = '[recovery-needed]';

  /// Native storage operations are only implemented for Android.
  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isAndroid;
  }

  static void _requireSupport() {
    if (!isSupported) {
      throw UnsupportedError('Native storage is only available on Android');
    }
  }

  /// Opens the system file picker and returns every picked document.
  static Future<List<NativeDocument>> pickFiles() async {
    _requireSupport();
    final result = await AppLock.guardExternal(
      () => _channel.invokeMethod<List<dynamic>>('pickFiles'),
    );
    if (result == null) return const [];
    return result
        .whereType<Map>()
        .map(NativeDocument.fromMap)
        .where((doc) => !doc.isDirectory)
        .toList(growable: false);
  }

  /// Opens the system folder picker. Returns `null` when cancelled.
  ///
  /// [initialDocId] opens the picker at that folder when the system allows it.
  static Future<NativeDocument?> pickFolder({String? initialDocId}) async {
    _requireSupport();
    final result = await AppLock.guardExternal(
      () => _channel.invokeMethod<Map<dynamic, dynamic>>(
        'pickFolder',
        initialDocId == null ? null : {'initialDocId': initialDocId},
      ),
    );
    return result == null ? null : NativeDocument.fromMap(result);
  }

  /// Lists every document below [treeUri]. Directories are included.
  static Future<List<NativeDocument>> listDocuments(
    String treeUri, {
    bool recursive = true,
  }) async {
    _requireSupport();
    final result = await _channel.invokeMethod<List<dynamic>>('listDocuments', {
      'treeUri': treeUri,
      'recursive': recursive,
    });
    if (result == null) return const [];
    return result
        .whereType<Map>()
        .map(NativeDocument.fromMap)
        .toList(growable: false);
  }

  /// Reads metadata for a single content URI.
  static Future<NativeDocument> describeDocument(String uri) async {
    _requireSupport();
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'describeDocument',
      {'uri': uri},
    );
    if (result == null) {
      throw StateError('Document is no longer accessible');
    }
    return NativeDocument.fromMap(result);
  }

  /// Checks whether [uri] still resolves and reports its current name and size.
  static Future<DocumentStat> statDocument(String uri) async {
    _requireSupport();
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'statDocument',
      {'uri': uri},
    );
    if (result == null) {
      return const DocumentStat(exists: false, name: '', size: 0);
    }
    return DocumentStat(
      exists: result['exists'] as bool? ?? false,
      name: result['name'] as String? ?? '',
      size: (result['size'] as num?)?.toInt() ?? 0,
    );
  }

  /// Free bytes in app storage, or `null` when it cannot be determined.
  static Future<int?> freeSpace() async {
    if (!isSupported) return null;
    try {
      final value = await _channel.invokeMethod<num>('freeSpace');
      return value?.toInt();
    } catch (_) {
      return null;
    }
  }

  /// Folder grants this app still holds with write access.
  static Future<List<String>> persistedTrees() async {
    _requireSupport();
    final result = await _channel.invokeMethod<List<dynamic>>('persistedTrees');
    return (result ?? const []).whereType<String>().toList(growable: false);
  }

  /// Finds the storage document id behind each picked uri.
  static Future<DocumentIds> resolveDocumentIds(List<String> uris) async {
    _requireSupport();
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'resolveDocumentIds',
      {'uris': uris},
    );
    final raw = result?['ids'];
    final ids = raw is List
        ? raw.map((value) => value as String?).toList(growable: false)
        : const <String?>[];
    return DocumentIds(sdk: (result?['sdk'] as num?)?.toInt() ?? 0, ids: ids);
  }

  /// Copies a content URI to a normal file path.
  ///
  /// When [maxBytes] is positive only the first [maxBytes] bytes are copied,
  /// which is enough to read a container header during recovery.
  static Future<void> copyDocumentToFile(
    String uri,
    String path, {
    int? maxBytes,
  }) async {
    _requireSupport();
    await _channel.invokeMethod<void>('copyDocumentToFile', {
      'uri': uri,
      'path': path,
      'maxBytes': ?maxBytes,
    });
  }

  /// Renames [uri] to [displayName], overwrites it with the container at
  /// [containerPath], and restores [backupPath] if anything fails.
  static Future<LockedDocument> replaceDocument({
    required String uri,
    required String containerPath,
    required String backupPath,
    required String displayName,
  }) async {
    _requireSupport();
    final result = await _channel
        .invokeMethod<Map<dynamic, dynamic>>('replaceDocument', {
          'uri': uri,
          'containerPath': containerPath,
          'backupPath': backupPath,
          'displayName': displayName,
        });
    if (result == null) {
      throw StateError('Could not replace document');
    }
    return LockedDocument.fromMap(result);
  }

  /// Writes [plaintextPath] over the encrypted document at [uri] and renames
  /// it back to [displayName].
  ///
  /// The container bytes at [backupPath] are written back if the operation
  /// fails, so a failed restore never leaves a half-written plaintext file
  /// behind.
  static Future<LockedDocument> restoreDocument({
    required String uri,
    required String plaintextPath,
    required String backupPath,
    required String displayName,
  }) async {
    _requireSupport();
    final result = await _channel
        .invokeMethod<Map<dynamic, dynamic>>('restoreDocument', {
          'uri': uri,
          'plaintextPath': plaintextPath,
          'backupPath': backupPath,
          'displayName': displayName,
        });
    if (result == null) {
      throw StateError('Could not restore document');
    }
    return LockedDocument.fromMap(result);
  }

  /// Deletes a document through SAF.
  static Future<void> deleteDocument(String uri) async {
    _requireSupport();
    await _channel.invokeMethod<bool>('deleteDocument', {'uri': uri});
  }

  /// Opens the system "save as" picker and copies [sourcePath] there.
  ///
  /// Returns the destination URI, or `null` if the user cancelled.
  static Future<String?> saveAs({
    required String sourcePath,
    required String displayName,
    required String mime,
  }) async {
    _requireSupport();
    return AppLock.guardExternal(
      () => _channel.invokeMethod<String>('saveAs', {
        'sourcePath': sourcePath,
        'displayName': displayName,
        'mime': mime,
      }),
    );
  }

  /// Shares a local cache file using a FileProvider content URI.
  static Future<void> shareFile({
    required String sourcePath,
    required String mime,
    required String displayName,
  }) async {
    _requireSupport();
    await _channel.invokeMethod<void>('shareFile', {
      'sourcePath': sourcePath,
      'mime': mime,
      'displayName': displayName,
    });
  }

  /// Opens a local cache file with the system's default viewer.
  static Future<void> openFile({
    required String sourcePath,
    required String mime,
    required String displayName,
  }) async {
    _requireSupport();
    await _channel.invokeMethod<void>('openFile', {
      'sourcePath': sourcePath,
      'mime': mime,
      'displayName': displayName,
    });
  }
}

/// Native Android AES-256-GCM chunk cipher used for large files.
class NativeContentCipher implements ContentCipher {
  NativeContentCipher._();

  static final NativeContentCipher instance = NativeContentCipher._();

  static const MethodChannel _channel = MethodChannel('curve_fault/storage');

  @override
  Future<void> encryptChunks({
    required String inputPath,
    required String outputPath,
    required Uint8List fileKey,
    required Uint8List headerHash,
    required int chunkSize,
    required bool append,
  }) async {
    if (!NativeStorage.isSupported) {
      return DartContentCipher.instance.encryptChunks(
        inputPath: inputPath,
        outputPath: outputPath,
        fileKey: fileKey,
        headerHash: headerHash,
        chunkSize: chunkSize,
        append: append,
      );
    }
    await _channel.invokeMethod<void>('encryptChunks', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'key': base64Encode(fileKey),
      'headerHash': base64Encode(headerHash),
      'chunkSize': chunkSize,
      'append': append,
    });
  }

  @override
  Future<void> decryptChunks({
    required String containerPath,
    required String outputPath,
    required Uint8List fileKey,
    required Uint8List headerHash,
    required int plaintextLength,
    required int chunkSize,
    required int chunkOffset,
  }) async {
    if (!NativeStorage.isSupported) {
      return DartContentCipher.instance.decryptChunks(
        containerPath: containerPath,
        outputPath: outputPath,
        fileKey: fileKey,
        headerHash: headerHash,
        plaintextLength: plaintextLength,
        chunkSize: chunkSize,
        chunkOffset: chunkOffset,
      );
    }
    await _channel.invokeMethod<void>('decryptChunks', {
      'containerPath': containerPath,
      'outputPath': outputPath,
      'key': base64Encode(fileKey),
      'headerHash': base64Encode(headerHash),
      'plaintextLength': plaintextLength,
      'chunkSize': chunkSize,
      'chunkOffset': chunkOffset,
    });
  }

  @override
  Future<void> verifyChunks({
    required String containerPath,
    required Uint8List fileKey,
    required Uint8List headerHash,
    required int plaintextLength,
    required int chunkSize,
    required int chunkOffset,
  }) async {
    if (!NativeStorage.isSupported) {
      return DartContentCipher.instance.verifyChunks(
        containerPath: containerPath,
        fileKey: fileKey,
        headerHash: headerHash,
        plaintextLength: plaintextLength,
        chunkSize: chunkSize,
        chunkOffset: chunkOffset,
      );
    }
    await _channel.invokeMethod<void>('verifyChunks', {
      'containerPath': containerPath,
      'key': base64Encode(fileKey),
      'headerHash': base64Encode(headerHash),
      'plaintextLength': plaintextLength,
      'chunkSize': chunkSize,
      'chunkOffset': chunkOffset,
    });
  }
}
