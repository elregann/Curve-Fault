import 'native_storage.dart';

enum AccessStatus { ready, needsAccess, unsupported }

/// A picked file together with what it takes to lock it in place.
class LockCandidate {
  const LockCandidate({
    required this.document,
    required this.status,
    required this.sourceUri,
    this.folderKey,
    this.folderName,
    this.reason,
  });

  /// For a ready file this carries the folder grant uri, otherwise the
  /// picked uri.
  final NativeDocument document;
  final AccessStatus status;

  /// The uri the system picker returned. Stays stable across re-checks.
  final String sourceUri;
  final String? folderKey;
  final String? folderName;
  final String? reason;
}

/// Works out whether a file chosen in the system picker can be locked in
/// place, using the folder grants the app already holds.
class LockAccess {
  LockAccess._();

  static String parentDocId(String docId) {
    final slash = docId.lastIndexOf('/');
    if (slash >= 0) return docId.substring(0, slash);
    final colon = docId.indexOf(':');
    return colon >= 0 ? docId.substring(0, colon + 1) : docId;
  }

  static String folderName(String parentId) {
    final slash = parentId.lastIndexOf('/');
    if (slash >= 0) return parentId.substring(slash + 1);
    final colon = parentId.indexOf(':');
    final rest = colon >= 0 ? parentId.substring(colon + 1) : parentId;
    return rest.isEmpty ? 'Storage root' : rest;
  }

  static String? treeDocId(String treeUri) {
    final segments = Uri.tryParse(treeUri)?.pathSegments;
    if (segments == null) return null;
    final index = segments.indexOf('tree');
    if (index < 0 || index + 1 >= segments.length) return null;
    return segments[index + 1];
  }

  static bool isInsideTree(String docId, String treeDocId) {
    if (treeDocId.endsWith(':')) {
      return docId.length > treeDocId.length && docId.startsWith(treeDocId);
    }
    return docId.startsWith('$treeDocId/');
  }

  static String buildTreeDocumentUri(String treeUri, String docId) {
    return '$treeUri/document/${Uri.encodeComponent(docId)}';
  }

  /// Folders Android will not hand out a grant for from Android 11 onward.
  static bool isRestrictedFolder(String parentId, int sdk) {
    if (sdk < 30) return false;
    if (parentId.endsWith(':')) return true;
    if (parentId == 'primary:Download') return true;
    final rest = parentId.substring(parentId.indexOf(':') + 1);
    return rest == 'Android/data' ||
        rest.startsWith('Android/data/') ||
        rest == 'Android/obb' ||
        rest.startsWith('Android/obb/');
  }

  static LockCandidate classify({
    required NativeDocument document,
    required String? docId,
    required int sdk,
    required List<String> trees,
  }) {
    if (docId == null) {
      return LockCandidate(
        document: document,
        status: AccessStatus.unsupported,
        sourceUri: document.uri,
        reason:
            'Could not find where this file is stored. Try Select Folder instead.',
      );
    }

    for (final tree in trees) {
      final treeId = treeDocId(tree);
      if (treeId == null || !isInsideTree(docId, treeId)) continue;
      final colon = docId.indexOf(':');
      final relative = colon >= 0
          ? docId.substring(colon + 1)
          : document.relativePath;
      return LockCandidate(
        document: document.withLocation(
          uri: buildTreeDocumentUri(tree, docId),
          relativePath: relative,
        ),
        status: AccessStatus.ready,
        sourceUri: document.uri,
      );
    }

    final parent = parentDocId(docId);
    final name = folderName(parent);
    if (isRestrictedFolder(parent, sdk)) {
      return LockCandidate(
        document: document,
        status: AccessStatus.unsupported,
        sourceUri: document.uri,
        reason:
            'Android does not allow access to $name. '
            'Move the file to another folder first.',
      );
    }
    return LockCandidate(
      document: document,
      status: AccessStatus.needsAccess,
      sourceUri: document.uri,
      folderKey: parent,
      folderName: name,
    );
  }

  /// Guards against locking a different file than the one the user picked.
  static bool matchesPicked(NativeDocument picked, DocumentStat stat) {
    if (!stat.exists || stat.name != picked.name) return false;
    return picked.size <= 0 || stat.size == picked.size;
  }

  static Map<String, List<LockCandidate>> groupNeedingAccess(
    List<LockCandidate> candidates,
  ) {
    final groups = <String, List<LockCandidate>>{};
    for (final candidate in candidates) {
      final key = candidate.folderKey;
      if (candidate.status != AccessStatus.needsAccess || key == null) continue;
      groups.putIfAbsent(key, () => <LockCandidate>[]).add(candidate);
    }
    return groups;
  }

  static Future<List<LockCandidate>> resolveAll(
    List<NativeDocument> documents,
  ) async {
    if (documents.isEmpty) return const [];
    final trees = await NativeStorage.persistedTrees();
    final resolved = await NativeStorage.resolveDocumentIds(
      documents.map((document) => document.uri).toList(growable: false),
    );

    final results = <LockCandidate>[];
    for (var i = 0; i < documents.length; i++) {
      final candidate = classify(
        document: documents[i],
        docId: i < resolved.ids.length ? resolved.ids[i] : null,
        sdk: resolved.sdk,
        trees: trees,
      );
      results.add(
        candidate.status == AccessStatus.ready
            ? await _verified(candidate)
            : candidate,
      );
    }
    return results;
  }

  static Future<LockCandidate> _verified(LockCandidate candidate) async {
    try {
      final stat = await NativeStorage.statDocument(candidate.document.uri);
      if (matchesPicked(candidate.document, stat)) return candidate;
    } catch (_) {
      // Treated as unconfirmed below.
    }
    return LockCandidate(
      document: candidate.document,
      status: AccessStatus.unsupported,
      sourceUri: candidate.sourceUri,
      reason: 'Could not confirm this is the same file',
    );
  }
}
