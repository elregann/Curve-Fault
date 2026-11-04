import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:path_provider/path_provider.dart';

import '../crypto/curve256189.dart';
import '../models/vault_entry.dart';
import 'native_storage.dart';
import 'session_service.dart';
import 'vault_crypto.dart';

/// Result of a bulk lock operation.
class VaultLockSummary {
  const VaultLockSummary({required this.locked, required this.failures});

  final int locked;
  final List<String> failures;

  bool get hasFailures => failures.isNotEmpty;
}

/// Journal record for a lock that started but is not yet in the index.
class PendingLock {
  const PendingLock({
    required this.id,
    required this.uri,
    required this.name,
    required this.mime,
    required this.relativePath,
    required this.addedAt,
    required this.size,
  });

  final String id;
  final String uri;
  final String name;
  final String mime;
  final String relativePath;
  final int addedAt;
  final int size;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'uri': uri,
      'name': name,
      'mime': mime,
      'relativePath': relativePath,
      'addedAt': addedAt,
      'size': size,
    };
  }

  factory PendingLock.fromJson(Map<String, dynamic> json) {
    return PendingLock(
      id: json['id'] as String,
      uri: json['uri'] as String,
      name: json['name'] as String? ?? 'Unknown',
      mime: json['mime'] as String? ?? 'application/octet-stream',
      relativePath: json['relativePath'] as String? ?? '',
      addedAt: (json['addedAt'] as num?)?.toInt() ?? 0,
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }
}

/// What to do with an interrupted lock when the vault is unlocked again.
enum PendingAction { drop, adopt, retry }

PendingAction decidePendingAction({
  required PendingLock record,
  required bool documentExists,
  required String documentName,
  required bool containerAvailable,
}) {
  if (!documentExists) return PendingAction.drop;
  if (documentName == '${record.id}.cvlt') return PendingAction.adopt;
  if (!containerAvailable) return PendingAction.drop;
  return PendingAction.retry;
}

/// Owns the encrypted vault catalogue and coordinates in-place locking.
///
/// The catalogue itself is a small JSON document encrypted with the vault key
/// and stored in app-private storage. The encrypted containers never leave the
/// folder the user picked.
class VaultService extends ChangeNotifier {
  VaultService._();

  static final VaultService instance = VaultService._();

  static const String _indexFileName = 'vault_index.cfi';
  static const List<int> _indexMagic = [0x43, 0x46, 0x49, 0x31]; // "CFI1"
  static const int _tagLength = 16;
  static const int _indexVersion = 1;

  Uint8List? _vaultKey;
  bool _unlocked = false;
  bool _busy = false;
  int _completed = 0;
  int _total = 0;
  String? _currentLabel;
  String? _indexWarning;
  final List<VaultEntry> _entries = <VaultEntry>[];
  final List<String> _lastFailures = <String>[];
  final List<PendingLock> _pending = <PendingLock>[];
  String? _recoveryNotice;
  Future<Directory>? _workDirFuture;

  List<VaultEntry> get entries => List<VaultEntry>.unmodifiable(_entries);
  Uint8List? get _privateKey => SessionService.masterSeed;
  bool get isUnlocked => _unlocked;
  bool get isBusy => _busy;
  int get completed => _completed;
  int get total => _total;
  String? get currentLabel => _currentLabel;
  String? get indexWarning => _indexWarning;
  String? get recoveryNotice => _recoveryNotice;
  List<String> get lastFailures => List<String>.unmodifiable(_lastFailures);

  @visibleForTesting
  void debugSetEntries(List<VaultEntry> entries) {
    _entries
      ..clear()
      ..addAll(entries);
    notifyListeners();
  }

  /// Derives the vault key and loads the encrypted index after unlock.
  Future<void> unlock(Uint8List seed) async {
    _vaultKey = VaultCrypto.deriveVaultKey(seed);
    VaultCrypto.defaultCipher = NativeContentCipher.instance;
    _unlocked = true;
    _recoveryNotice = null;
    await _cleanWorkDir();
    await _loadIndex();
    await _resolvePending();
    notifyListeners();
  }

  /// Clears all in-memory vault state. Called by the wipe flow.
  Future<void> lockAndClear() async {
    _entries.clear();
    _pending.clear();
    _vaultKey?.fillRange(0, _vaultKey!.length, 0);
    _vaultKey = null;
    _unlocked = false;
    _indexWarning = null;
    _recoveryNotice = null;
    _busy = false;
    await _cleanWorkDir();
    _safeDelete(Directory('${(await _supportDir()).path}/pending'));
    notifyListeners();
  }

  /// Drops the keys and in-memory catalogue without touching files on disk.
  /// Used by the auto lock when the app returns from the background.
  void lockSession() {
    _entries.clear();
    _pending.clear();
    _vaultKey?.fillRange(0, _vaultKey!.length, 0);
    _vaultKey = null;
    _unlocked = false;
    _indexWarning = null;
    _recoveryNotice = null;
    notifyListeners();
  }

  /// Locks the given documents in place.
  Future<VaultLockSummary> lockDocuments(List<NativeDocument> documents) async {
    _requireUnlocked();
    final files = documents.where((doc) => !doc.isDirectory).toList();
    if (files.isEmpty) {
      return const VaultLockSummary(locked: 0, failures: []);
    }

    _beginBatch(files.length);
    _lastFailures.clear();
    var locked = 0;
    try {
      for (final doc in files) {
        _currentLabel = doc.name;
        notifyListeners();
        try {
          await _lockOne(doc);
          locked++;
        } catch (error) {
          _lastFailures.add('${doc.name}: ${_messageFor(error)}');
        }
        _completed++;
        notifyListeners();
      }
    } finally {
      _endBatch();
    }
    await _saveIndex();
    return VaultLockSummary(
      locked: locked,
      failures: List<String>.unmodifiable(_lastFailures),
    );
  }

  /// Locks every file inside a folder selected with SAF.
  Future<VaultLockSummary> lockFolder(NativeDocument folder) async {
    _requireUnlocked();
    _beginBatch(0);
    _lastFailures.clear();
    try {
      _currentLabel = 'Scanning ${folder.name}';
      notifyListeners();
      final all = await NativeStorage.listDocuments(folder.uri);
      final files = all
          .where((doc) => !doc.isDirectory)
          .where((doc) => !_isVaultContainer(doc.name))
          .where((doc) => !isHiddenPath(doc.relativePath))
          .toList(growable: false);
      if (files.isEmpty) {
        return const VaultLockSummary(locked: 0, failures: []);
      }

      _total = files.length;
      notifyListeners();

      var locked = 0;
      for (final doc in files) {
        _currentLabel = doc.name;
        notifyListeners();
        try {
          await _lockOne(doc);
          locked++;
        } catch (error) {
          _lastFailures.add('${doc.name}: ${_messageFor(error)}');
        }
        _completed++;
        notifyListeners();
      }
      await _saveIndex();
      return VaultLockSummary(
        locked: locked,
        failures: List<String>.unmodifiable(_lastFailures),
      );
    } finally {
      _endBatch();
    }
  }

  /// Lists the files a folder lock would touch, skipping containers and
  /// anything hidden.
  Future<List<NativeDocument>> scanFolder(NativeDocument folder) async {
    final all = await NativeStorage.listDocuments(folder.uri);
    return all
        .where((doc) => !doc.isDirectory)
        .where((doc) => !_isVaultContainer(doc.name))
        .where((doc) => !isHiddenPath(doc.relativePath))
        .toList(growable: false);
  }

  /// Rebuilds index entries from the `.cvlt` files in [folder].
  ///
  /// Useful after reinstalling the app or if the private index was lost.
  Future<VaultLockSummary> recoverFolder(NativeDocument folder) async {
    _requireUnlocked();
    _beginBatch(1);
    _lastFailures.clear();
    try {
      _currentLabel = 'Scanning ${folder.name}';
      notifyListeners();
      final all = await NativeStorage.listDocuments(folder.uri);
      final containers = all
          .where((doc) => !doc.isDirectory && _isVaultContainer(doc.name))
          .toList(growable: false);
      return await _recoverContainers(containers);
    } finally {
      _endBatch();
    }
  }

  /// Imports one or more shared `.cvlt` files into the local index.
  ///
  /// A shared container can be opened with either the local vault key or the
  /// Curve256189 identity key, so recipients do not need the sender's seed.
  Future<VaultLockSummary> importFiles(List<NativeDocument> documents) async {
    _requireUnlocked();
    _beginBatch(1);
    _lastFailures.clear();
    try {
      final containers = documents
          .where((doc) => !doc.isDirectory && _isVaultContainer(doc.name))
          .toList(growable: false);
      return await _recoverContainers(containers);
    } finally {
      _endBatch();
    }
  }

  Future<VaultLockSummary> _recoverContainers(
    List<NativeDocument> containers,
  ) async {
    _total = containers.length;
    _completed = 0;
    notifyListeners();

    var recovered = 0;
    final work = await _workDir();
    for (final doc in containers) {
      _currentLabel = doc.name;
      notifyListeners();
      final temp = File(
        '${work.path}/recover_${DateTime.now().microsecondsSinceEpoch}.hdr',
      );
      try {
        await NativeStorage.copyDocumentToFile(
          doc.uri,
          temp.path,
          maxBytes: 256 * 1024,
        );
        final info = VaultCrypto.readInfo(
          containerPath: temp.path,
          vaultKey: _vaultKey!,
          privateKey: _privateKey,
        );
        final id = (info.metadata['id'] as String?)?.trim();
        final resolvedId = (id == null || id.isEmpty)
            ? _fallbackId(doc.uri)
            : id;
        if (_entries.any((entry) => entry.id == resolvedId)) {
          continue;
        }
        final entry = VaultEntry(
          id: resolvedId,
          uri: doc.uri,
          name:
              info.metadata['name'] as String? ??
              _stripContainerSuffix(doc.name),
          mime: info.metadata['mime'] as String? ?? 'application/octet-stream',
          size: info.plaintextLength,
          relativePath:
              info.metadata['relativePath'] as String? ?? doc.relativePath,
          addedAt:
              (info.metadata['addedAt'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
        );
        _entries.add(entry);
        recovered++;
      } catch (error) {
        _lastFailures.add('${doc.name}: ${_messageFor(error)}');
      } finally {
        _safeDelete(temp);
        _completed++;
        notifyListeners();
      }
    }

    _entries.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    await _saveIndex();
    return VaultLockSummary(
      locked: recovered,
      failures: List<String>.unmodifiable(_lastFailures),
    );
  }

  /// Decrypts [entry] into the private cache and returns the plaintext file.
  Future<File> decryptToTemp(VaultEntry entry) async {
    _requireUnlocked();
    final work = await _workDir();
    final id = DateTime.now().microsecondsSinceEpoch;
    final container = File('${work.path}/${entry.id}_$id.cvlt');
    final output = File('${work.path}/${_safeFileName(entry.name)}');
    try {
      await NativeStorage.copyDocumentToFile(entry.uri, container.path);
      await VaultCrypto.decryptFile(
        containerPath: container.path,
        outputPath: output.path,
        vaultKey: _vaultKey!,
        privateKey: _privateKey,
      );
      return output;
    } catch (_) {
      _safeDelete(output);
      rethrow;
    } finally {
      _safeDelete(container);
    }
  }

  /// Opens the system save-as picker and writes a decrypted copy there.
  Future<bool> saveAs(VaultEntry entry) async {
    final file = await decryptToTemp(entry);
    try {
      final result = await NativeStorage.saveAs(
        sourcePath: file.path,
        displayName: entry.name,
        mime: entry.mime,
      );
      return result != null;
    } finally {
      _safeDelete(file);
    }
  }

  /// Restores [entry] to its original file name and location.
  ///
  /// The container is decrypted to the private cache first, then written over
  /// the container document and renamed back to the original name. The index
  /// entry is only removed after the plaintext is safely on disk.
  Future<void> restore(VaultEntry entry) async {
    _requireUnlocked();
    final work = await _workDir();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final container = File('${work.path}/${entry.id}_$stamp.cvlt');
    final plaintext = File('${work.path}/restore_$stamp.plain');
    try {
      await NativeStorage.copyDocumentToFile(entry.uri, container.path);
      await VaultCrypto.decryptFile(
        containerPath: container.path,
        outputPath: plaintext.path,
        vaultKey: _vaultKey!,
        privateKey: _privateKey,
      );
      await NativeStorage.restoreDocument(
        uri: entry.uri,
        plaintextPath: plaintext.path,
        backupPath: container.path,
        displayName: entry.name,
      );
      _entries.removeWhere((candidate) => candidate.id == entry.id);
      await _saveIndex();
      notifyListeners();
    } finally {
      _safeDelete(container);
      _safeDelete(plaintext);
    }
  }

  /// Restores several entries one after another with batch progress.
  Future<VaultLockSummary> restoreEntries(List<VaultEntry> entries) async {
    _requireUnlocked();
    _beginBatch(entries.length);
    _lastFailures.clear();
    var restored = 0;
    try {
      for (final entry in entries) {
        _currentLabel = entry.name;
        notifyListeners();
        try {
          await restore(entry);
          restored++;
        } catch (error) {
          _lastFailures.add('${entry.name}: ${_messageFor(error)}');
        }
        _completed++;
        notifyListeners();
      }
    } finally {
      _endBatch();
    }
    return VaultLockSummary(
      locked: restored,
      failures: List<String>.unmodifiable(_lastFailures),
    );
  }

  /// Shares a decrypted copy using the system share sheet.
  Future<void> share(VaultEntry entry) async {
    final file = await decryptToTemp(entry);
    await NativeStorage.shareFile(
      sourcePath: file.path,
      mime: entry.mime,
      displayName: entry.name,
    );
    _scheduleCleanup(file);
  }

  /// Re-encrypts [entry] with a Curve256189 recipient slot and shares the new
  /// `.cvlt` container. The recipient needs their identity key, not the sender's
  /// vault seed.
  Future<void> shareWithIdentity(
    VaultEntry entry,
    Uint8List recipientPublicKey,
  ) async {
    _requireUnlocked();
    if (recipientPublicKey.length != 32) {
      throw VaultCryptoException('Recipient public key must be 32 bytes');
    }

    final work = await _workDir();
    final plaintext = await decryptToTemp(entry);
    final container = File(
      '${work.path}/share_${DateTime.now().microsecondsSinceEpoch}.cvlt',
    );
    var shared = false;
    try {
      final sharedId = _newEntryId();
      await VaultCrypto.encryptFile(
        inputPath: plaintext.path,
        outputPath: container.path,
        vaultKey: _vaultKey!,
        metadata: {
          'id': sharedId,
          'name': entry.name,
          'mime': entry.mime,
          'relativePath': entry.relativePath,
          'addedAt': DateTime.now().millisecondsSinceEpoch,
          'shared': true,
        },
        recipientPublicKey: recipientPublicKey,
      );
      await VaultCrypto.verifyFile(
        containerPath: container.path,
        vaultKey: _vaultKey!,
        privateKey: _privateKey,
      );
      await NativeStorage.shareFile(
        sourcePath: container.path,
        mime: 'application/octet-stream',
        displayName: '${entry.name}.cvlt',
      );
      shared = true;
      _scheduleCleanup(container);
      _scheduleCleanup(plaintext);
    } finally {
      if (!shared) {
        _safeDelete(container);
        _safeDelete(plaintext);
      }
    }
  }

  /// Opens a decrypted copy with the system's default viewer.
  Future<void> open(VaultEntry entry) async {
    final file = await decryptToTemp(entry);
    await NativeStorage.openFile(
      sourcePath: file.path,
      mime: entry.mime,
      displayName: entry.name,
    );
    _scheduleCleanup(file);
  }

  /// Deletes the encrypted containers and removes their index entries.
  Future<List<String>> deleteEntries(List<VaultEntry> entries) async {
    _requireUnlocked();
    final failures = <String>[];
    for (final entry in entries) {
      try {
        await NativeStorage.deleteDocument(entry.uri);
        _entries.removeWhere((candidate) => candidate.id == entry.id);
      } catch (error) {
        failures.add('${entry.name}: ${_messageFor(error)}');
      }
    }
    await _saveIndex();
    notifyListeners();
    return failures;
  }

  Future<VaultEntry> _lockOne(NativeDocument doc) async {
    final work = await _workDir();
    final pendingDir = await _pendingDir();
    final id = _newEntryId();
    final plain = File('${work.path}/$id.plain');
    final container = File('${pendingDir.path}/$id.cvlt');
    var journaled = false;
    var keepPending = false;
    try {
      await _ensureFreeSpace(doc.size);
      await NativeStorage.copyDocumentToFile(doc.uri, plain.path);
      final addedAt = DateTime.now().millisecondsSinceEpoch;
      final info = await VaultCrypto.encryptFile(
        inputPath: plain.path,
        outputPath: container.path,
        vaultKey: _vaultKey!,
        metadata: {
          'id': id,
          'name': doc.name,
          'mime': doc.mime,
          'relativePath': doc.relativePath,
          'addedAt': addedAt,
        },
      );
      await VaultCrypto.verifyFile(
        containerPath: container.path,
        vaultKey: _vaultKey!,
      );

      _pending.add(
        PendingLock(
          id: id,
          uri: doc.uri,
          name: doc.name,
          mime: doc.mime,
          relativePath: doc.relativePath,
          addedAt: addedAt,
          size: info.plaintextLength,
        ),
      );
      journaled = true;
      await _saveIndex();

      final LockedDocument locked;
      try {
        locked = await NativeStorage.replaceDocument(
          uri: doc.uri,
          containerPath: container.path,
          backupPath: plain.path,
          displayName: '$id.cvlt',
        );
      } catch (error) {
        keepPending = error.toString().contains(NativeStorage.recoveryMarker);
        rethrow;
      }

      final entry = VaultEntry(
        id: id,
        uri: locked.uri,
        name: doc.name,
        mime: doc.mime,
        size: info.plaintextLength,
        relativePath: doc.relativePath,
        addedAt: addedAt,
      );
      _entries.insert(0, entry);
      _pending.removeWhere((candidate) => candidate.id == id);
      journaled = false;
      await _saveIndex();
      return entry;
    } finally {
      _safeDelete(plain);
      if (!keepPending) {
        _safeDelete(container);
        if (journaled) {
          _pending.removeWhere((candidate) => candidate.id == id);
          await _saveIndex();
        }
      }
    }
  }

  Future<Directory> _pendingDir() async {
    final dir = Directory('${(await _supportDir()).path}/pending');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<void> _ensureFreeSpace(int fileSize) async {
    if (fileSize <= 0) return;
    final free = await NativeStorage.freeSpace();
    if (free == null) return;
    final needed = fileSize * 2 + 8 * 1024 * 1024;
    if (free < needed) {
      throw VaultCryptoException('Not enough free storage to lock this file');
    }
  }

  void _adoptPending(PendingLock record, String uri) {
    if (_entries.any((entry) => entry.id == record.id)) return;
    _entries.insert(
      0,
      VaultEntry(
        id: record.id,
        uri: uri,
        name: record.name,
        mime: record.mime,
        size: record.size,
        relativePath: record.relativePath,
        addedAt: record.addedAt,
      ),
    );
  }

  /// Finishes or discards locks that were interrupted by a crash or kill.
  Future<void> _resolvePending() async {
    if (_pending.isEmpty) return;
    final pendingDir = await _pendingDir();
    var lost = 0;
    var failed = 0;
    for (final record in List<PendingLock>.of(_pending)) {
      final container = File('${pendingDir.path}/${record.id}.cvlt');
      try {
        final stat = await NativeStorage.statDocument(record.uri);
        final action = decidePendingAction(
          record: record,
          documentExists: stat.exists,
          documentName: stat.name,
          containerAvailable: container.existsSync(),
        );
        switch (action) {
          case PendingAction.drop:
            if (!stat.exists) lost++;
          case PendingAction.adopt:
            _adoptPending(record, record.uri);
          case PendingAction.retry:
            {
              final locked = await NativeStorage.replaceDocument(
                uri: record.uri,
                containerPath: container.path,
                backupPath: container.path,
                displayName: '${record.id}.cvlt',
              );
              _adoptPending(record, locked.uri);
            }
        }
        _pending.removeWhere((candidate) => candidate.id == record.id);
        _safeDelete(container);
      } catch (_) {
        failed++;
      }
    }
    await _saveIndex();
    final notes = <String>[];
    if (lost > 0) {
      notes.add(
        'A lock was interrupted. Run Recover Folder on the original folder '
        'to find locked files that were not indexed.',
      );
    }
    if (failed > 0) {
      notes.add(
        'Some interrupted locks could not be finished and will be retried '
        'on the next unlock.',
      );
    }
    if (notes.isNotEmpty) {
      _recoveryNotice = notes.join(' ');
    }
  }

  Future<void> _loadIndex() async {
    _entries.clear();
    _pending.clear();
    _indexWarning = null;
    final key = _vaultKey;
    if (key == null) return;

    final file = File('${(await _supportDir()).path}/$_indexFileName');
    if (!file.existsSync()) return;

    try {
      final bytes = file.readAsBytesSync();
      final plaintext = _decryptIndex(bytes, key);
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is! Map) {
        throw const FormatException('Invalid vault index');
      }
      final rawPending = decoded['pending'];
      if (rawPending is List) {
        for (final raw in rawPending) {
          if (raw is! Map) continue;
          try {
            _pending.add(PendingLock.fromJson(Map<String, dynamic>.from(raw)));
          } catch (_) {
            // A malformed journal record is skipped.
          }
        }
      }
      final rawEntries = decoded['entries'];
      if (rawEntries is List) {
        for (final raw in rawEntries) {
          if (raw is Map) {
            _entries.add(VaultEntry.fromJson(Map<String, dynamic>.from(raw)));
          }
        }
      }
      _entries.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    } catch (_) {
      _indexWarning =
          'The vault index could not be read. Encrypted files are still on disk.';
    }
  }

  Future<void> _saveIndex() async {
    final key = _vaultKey;
    if (key == null) return;
    try {
      final dir = await _supportDir();
      final file = File('${dir.path}/$_indexFileName');
      final temp = File('${file.path}.tmp');
      final payload = <String, dynamic>{
        'version': _indexVersion,
        'entries': _entries.map((entry) => entry.toJson()).toList(),
        'pending': _pending.map((record) => record.toJson()).toList(),
      };
      final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
      temp.writeAsBytesSync(_encryptIndex(plaintext, key), flush: true);
      if (file.existsSync()) {
        file.deleteSync();
      }
      temp.renameSync(file.path);
      _indexWarning = null;
    } catch (_) {
      _indexWarning =
          'Could not save the vault index. The encrypted files are unaffected.';
    }
  }

  Uint8List _encryptIndex(Uint8List plaintext, Uint8List key) {
    final nonce = VaultCrypto.randomBytes(12);
    final encrypted = AESGCM.encrypt(
      key: key,
      nonce: nonce,
      plaintext: plaintext,
      aad: Uint8List.fromList(utf8.encode('CurveVault-index-v1')),
    );
    final length = ByteData(4)
      ..setUint32(0, encrypted.ciphertext.length, Endian.little);
    return Uint8List.fromList([
      ..._indexMagic,
      ...nonce,
      ...length.buffer.asUint8List(),
      ...encrypted.ciphertext,
      ...encrypted.tag,
    ]);
  }

  Uint8List _decryptIndex(Uint8List bytes, Uint8List key) {
    if (bytes.length < 4 + 12 + 4 + _tagLength) {
      throw const FormatException('Vault index is truncated');
    }
    for (var i = 0; i < _indexMagic.length; i++) {
      if (bytes[i] != _indexMagic[i]) {
        throw const FormatException('Not a vault index');
      }
    }
    final nonce = Uint8List.fromList(bytes.sublist(4, 16));
    final length = ByteData.sublistView(
      bytes,
      16,
      20,
    ).getUint32(0, Endian.little);
    final cipherStart = 20;
    final cipherEnd = cipherStart + length;
    if (cipherEnd + _tagLength > bytes.length) {
      throw const FormatException('Vault index is truncated');
    }
    final ciphertext = Uint8List.fromList(
      bytes.sublist(cipherStart, cipherEnd),
    );
    final tag = Uint8List.fromList(
      bytes.sublist(cipherEnd, cipherEnd + _tagLength),
    );
    final plaintext = AESGCM.decrypt(
      key: key,
      nonce: nonce,
      ciphertext: ciphertext,
      tag: tag,
      aad: Uint8List.fromList(utf8.encode('CurveVault-index-v1')),
    );
    if (plaintext == null) {
      throw const FormatException('Vault index integrity check failed');
    }
    return plaintext;
  }

  Future<Directory> _supportDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/CurveVault');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<Directory> _workDir() async {
    return _workDirFuture ??= () async {
      final cache = await getTemporaryDirectory();
      final dir = Directory('${cache.path}/curve_vault_work');
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      return dir;
    }();
  }

  Future<void> _cleanWorkDir() async {
    try {
      final dir = await _workDir();
      if (!dir.existsSync()) return;
      for (final item in dir.listSync()) {
        _safeDelete(item);
      }
    } catch (_) {
      // Cleanup is best-effort only.
    }
  }

  void _scheduleCleanup(File file) {
    Future<void>.delayed(const Duration(minutes: 10), () {
      _safeDelete(file);
    });
  }

  void _beginBatch(int total) {
    _busy = true;
    _completed = 0;
    _total = total;
    _currentLabel = null;
    notifyListeners();
  }

  void _endBatch() {
    _busy = false;
    _currentLabel = null;
    notifyListeners();
  }

  void _requireUnlocked() {
    if (!_unlocked || _vaultKey == null) {
      throw StateError('Vault is locked');
    }
  }

  static bool _isVaultContainer(String name) {
    return name.toLowerCase().endsWith('.cvlt');
  }

  static String _stripContainerSuffix(String name) {
    if (!_isVaultContainer(name)) return name;
    return name.substring(0, name.length - 5);
  }

  static String _fallbackId(String uri) {
    final bytes = utf8.encode(uri);
    final digest = sha256.convert(bytes).bytes;
    return digest
        .take(8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static String _newEntryId() {
    return VaultCrypto.randomBytes(
      12,
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _safeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    final trimmed = cleaned.trim();
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') {
      return 'file';
    }
    return trimmed;
  }

  static String _messageFor(Object error) {
    if (error is VaultCryptoException) return error.message;
    if (error is PlatformException) {
      final raw = error.message ?? error.code;
      return raw
          .replaceAll(
            NativeStorage.recoveryMarker,
            'It will be finished on the next unlock.',
          )
          .trim();
    }
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  static void _safeDelete(FileSystemEntity entity) {
    try {
      if (entity.existsSync()) {
        entity.deleteSync(recursive: true);
      }
    } catch (_) {
      // Best-effort cleanup.
    }
  }
}
