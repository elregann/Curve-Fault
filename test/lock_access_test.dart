import 'package:curve_fault/services/lock_access.dart';
import 'package:curve_fault/services/native_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _dcimTree =
    'content://com.android.externalstorage.documents/tree/primary%3ADCIM';
const _picturesTree =
    'content://com.android.externalstorage.documents/tree/primary%3APictures';

NativeDocument _doc(String name, {int size = 100}) {
  return NativeDocument(
    uri: 'content://com.android.providers.media.documents/document/image%3A$name',
    name: name,
    mime: 'image/jpeg',
    size: size,
    relativePath: name,
    parentUri: '',
    lastModified: 0,
    isDirectory: false,
    canWrite: true,
  );
}

void main() {
  group('parentDocId', () {
    test('drops the file name', () {
      expect(
        LockAccess.parentDocId('primary:DCIM/Camera/x.jpg'),
        'primary:DCIM/Camera',
      );
    });

    test('returns the volume root for a file at the top level', () {
      expect(LockAccess.parentDocId('primary:x.jpg'), 'primary:');
    });

    test('keeps other volumes intact', () {
      expect(
        LockAccess.parentDocId('1A2B-3C4D:Pics/y.png'),
        '1A2B-3C4D:Pics',
      );
    });
  });

  group('folderName', () {
    test('uses the last folder segment', () {
      expect(LockAccess.folderName('primary:DCIM/Camera'), 'Camera');
      expect(LockAccess.folderName('primary:Pictures'), 'Pictures');
    });

    test('names the volume root', () {
      expect(LockAccess.folderName('primary:'), 'Storage root');
    });
  });

  group('treeDocId', () {
    test('reads the document id of a tree uri', () {
      expect(LockAccess.treeDocId(_dcimTree), 'primary:DCIM');
    });

    test('decodes nested folders', () {
      expect(
        LockAccess.treeDocId(
          'content://com.android.externalstorage.documents/tree/'
          'primary%3ADCIM%2FCamera',
        ),
        'primary:DCIM/Camera',
      );
    });

    test('returns null when the uri has no tree segment', () {
      expect(
        LockAccess.treeDocId('content://x/document/primary%3Aa.jpg'),
        isNull,
      );
    });
  });

  group('isInsideTree', () {
    test('accepts files below the tree folder', () {
      expect(
        LockAccess.isInsideTree('primary:DCIM/Camera/x.jpg', 'primary:DCIM'),
        isTrue,
      );
    });

    test('rejects a sibling that only shares a name prefix', () {
      expect(
        LockAccess.isInsideTree('primary:DCIM2/x.jpg', 'primary:DCIM'),
        isFalse,
      );
    });

    test('rejects the tree folder itself', () {
      expect(
        LockAccess.isInsideTree('primary:DCIM', 'primary:DCIM'),
        isFalse,
      );
    });

    test('a volume root tree covers that volume only', () {
      expect(LockAccess.isInsideTree('primary:a.jpg', 'primary:'), isTrue);
      expect(LockAccess.isInsideTree('1A2B-3C4D:a.jpg', 'primary:'), isFalse);
    });
  });

  group('buildTreeDocumentUri', () {
    test('appends the encoded document id', () {
      expect(
        LockAccess.buildTreeDocumentUri(
          _dcimTree,
          'primary:DCIM/Camera/a b.jpg',
        ),
        'content://com.android.externalstorage.documents/tree/primary%3ADCIM'
        '/document/primary%3ADCIM%2FCamera%2Fa%20b.jpg',
      );
    });
  });

  group('isRestrictedFolder', () {
    test('blocks the Download folder from Android 11', () {
      expect(LockAccess.isRestrictedFolder('primary:Download', 30), isTrue);
      expect(LockAccess.isRestrictedFolder('primary:Download', 29), isFalse);
    });

    test('allows subfolders of Download', () {
      expect(
        LockAccess.isRestrictedFolder('primary:Download/Docs', 33),
        isFalse,
      );
    });

    test('blocks volume roots from Android 11', () {
      expect(LockAccess.isRestrictedFolder('primary:', 33), isTrue);
      expect(LockAccess.isRestrictedFolder('1A2B-3C4D:', 31), isTrue);
      expect(LockAccess.isRestrictedFolder('primary:', 29), isFalse);
    });

    test('blocks the app data folders', () {
      expect(
        LockAccess.isRestrictedFolder('primary:Android/data/com.x', 33),
        isTrue,
      );
      expect(LockAccess.isRestrictedFolder('primary:Android/obb', 30), isTrue);
    });

    test('allows ordinary media folders', () {
      expect(LockAccess.isRestrictedFolder('primary:DCIM/Camera', 34), isFalse);
    });
  });

  group('classify', () {
    test('is ready when a persisted tree already covers the file', () {
      final doc = _doc('gajah.jpg');
      final result = LockAccess.classify(
        document: doc,
        docId: 'primary:DCIM/Camera/gajah.jpg',
        sdk: 34,
        trees: const [_picturesTree, _dcimTree],
      );

      expect(result.status, AccessStatus.ready);
      expect(
        result.document.uri,
        LockAccess.buildTreeDocumentUri(
          _dcimTree,
          'primary:DCIM/Camera/gajah.jpg',
        ),
      );
      expect(result.document.relativePath, 'DCIM/Camera/gajah.jpg');
      expect(result.document.name, 'gajah.jpg');
      expect(result.sourceUri, doc.uri);
    });

    test('needs access when no tree covers the file', () {
      final doc = _doc('gajah.jpg');
      final result = LockAccess.classify(
        document: doc,
        docId: 'primary:DCIM/Camera/gajah.jpg',
        sdk: 34,
        trees: const [],
      );

      expect(result.status, AccessStatus.needsAccess);
      expect(result.folderKey, 'primary:DCIM/Camera');
      expect(result.folderName, 'Camera');
      expect(result.document.uri, doc.uri);
    });

    test('needs access when only an unrelated tree is granted', () {
      final result = LockAccess.classify(
        document: _doc('gajah.jpg'),
        docId: 'primary:DCIM/Camera/gajah.jpg',
        sdk: 34,
        trees: const [_picturesTree],
      );
      expect(result.status, AccessStatus.needsAccess);
    });

    test('is unsupported when the location cannot be resolved', () {
      final result = LockAccess.classify(
        document: _doc('gajah.jpg'),
        docId: null,
        sdk: 34,
        trees: const [_dcimTree],
      );
      expect(result.status, AccessStatus.unsupported);
      expect(result.reason, isNotNull);
    });

    test('is unsupported for a file directly in Download on Android 13', () {
      final result = LockAccess.classify(
        document: _doc('invoice.pdf'),
        docId: 'primary:Download/invoice.pdf',
        sdk: 33,
        trees: const [],
      );
      expect(result.status, AccessStatus.unsupported);
      expect(result.reason, contains('Download'));
    });

    test('still asks for access to Download on Android 10', () {
      final result = LockAccess.classify(
        document: _doc('invoice.pdf'),
        docId: 'primary:Download/invoice.pdf',
        sdk: 29,
        trees: const [],
      );
      expect(result.status, AccessStatus.needsAccess);
    });
  });

  group('matchesPicked', () {
    const found = DocumentStat(exists: true, name: 'a.jpg', size: 100);

    test('accepts the same name and size', () {
      expect(LockAccess.matchesPicked(_doc('a.jpg'), found), isTrue);
    });

    test('accepts an unknown picked size', () {
      expect(LockAccess.matchesPicked(_doc('a.jpg', size: 0), found), isTrue);
    });

    test('rejects a different name', () {
      expect(LockAccess.matchesPicked(_doc('b.jpg'), found), isFalse);
    });

    test('rejects a different size', () {
      expect(LockAccess.matchesPicked(_doc('a.jpg', size: 7), found), isFalse);
    });

    test('rejects a missing document', () {
      const missing = DocumentStat(exists: false, name: '', size: 0);
      expect(LockAccess.matchesPicked(_doc('a.jpg'), missing), isFalse);
    });
  });

  group('groupNeedingAccess', () {
    test('groups only files that need access, by folder', () {
      final candidates = [
        LockAccess.classify(
          document: _doc('a.jpg'),
          docId: 'primary:DCIM/Camera/a.jpg',
          sdk: 34,
          trees: const [],
        ),
        LockAccess.classify(
          document: _doc('b.jpg'),
          docId: 'primary:DCIM/Camera/b.jpg',
          sdk: 34,
          trees: const [],
        ),
        LockAccess.classify(
          document: _doc('c.jpg'),
          docId: 'primary:Pictures/Shots/c.jpg',
          sdk: 34,
          trees: const [],
        ),
        LockAccess.classify(
          document: _doc('d.jpg'),
          docId: 'primary:DCIM/Camera/d.jpg',
          sdk: 34,
          trees: const [_dcimTree],
        ),
      ];

      final groups = LockAccess.groupNeedingAccess(candidates);

      expect(groups.keys.toSet(), {
        'primary:DCIM/Camera',
        'primary:Pictures/Shots',
      });
      expect(groups['primary:DCIM/Camera']!.length, 2);
      expect(groups['primary:Pictures/Shots']!.length, 1);
    });
  });
}
