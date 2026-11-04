import 'package:curve_fault/services/app_lock.dart';
import 'package:curve_fault/services/native_storage.dart';
import 'package:curve_fault/services/vault_service.dart';
import 'package:curve_fault/widgets/document_picker.dart';
import 'package:flutter_test/flutter_test.dart';

NativeDocument _doc(String path) {
  return NativeDocument(
    uri: 'content://docs/$path',
    name: path.split('/').last,
    mime: 'image/jpeg',
    size: 10,
    relativePath: path,
    parentUri: '',
    lastModified: 0,
    isDirectory: false,
    canWrite: true,
  );
}

const _record = PendingLock(
  id: 'abc123',
  uri: 'content://x/tree/a/document/a%3Ap.jpg',
  name: 'p.jpg',
  mime: 'image/jpeg',
  relativePath: 'DCIM/p.jpg',
  addedAt: 1700000000000,
  size: 2048,
);

void main() {
  group('PendingLock', () {
    test('round trips through json', () {
      final copy = PendingLock.fromJson(_record.toJson());
      expect(copy.id, _record.id);
      expect(copy.uri, _record.uri);
      expect(copy.name, _record.name);
      expect(copy.mime, _record.mime);
      expect(copy.relativePath, _record.relativePath);
      expect(copy.addedAt, _record.addedAt);
      expect(copy.size, _record.size);
    });

    test('fromJson tolerates missing optional fields', () {
      final copy = PendingLock.fromJson({'id': 'x', 'uri': 'content://y'});
      expect(copy.name, 'Unknown');
      expect(copy.mime, 'application/octet-stream');
      expect(copy.size, 0);
    });
  });

  group('decidePendingAction', () {
    test('drops the record when the document is gone', () {
      expect(
        decidePendingAction(
          record: _record,
          documentExists: false,
          documentName: '',
          containerAvailable: true,
        ),
        PendingAction.drop,
      );
    });

    test('adopts a document that already carries the container name', () {
      expect(
        decidePendingAction(
          record: _record,
          documentExists: true,
          documentName: 'abc123.cvlt',
          containerAvailable: false,
        ),
        PendingAction.adopt,
      );
    });

    test('retries when the original name remains and the container is kept', () {
      expect(
        decidePendingAction(
          record: _record,
          documentExists: true,
          documentName: 'p.jpg',
          containerAvailable: true,
        ),
        PendingAction.retry,
      );
    });

    test('drops when the original name remains but the container is lost', () {
      expect(
        decidePendingAction(
          record: _record,
          documentExists: true,
          documentName: 'p.jpg',
          containerAvailable: false,
        ),
        PendingAction.drop,
      );
    });
  });

  group('isHiddenPath', () {
    test('flags hidden files and folders at any depth', () {
      expect(isHiddenPath('.nomedia'), isTrue);
      expect(isHiddenPath('.thumbnails/a.jpg'), isTrue);
      expect(isHiddenPath('DCIM/.trash/a.jpg'), isTrue);
    });

    test('keeps ordinary paths', () {
      expect(isHiddenPath('a.jpg'), isFalse);
      expect(isHiddenPath('DCIM/Camera/a.b.jpg'), isFalse);
    });
  });

  group('filterPickerFiles', () {
    final files = [_doc('a.jpg'), _doc('sub/b.jpg'), _doc('sub/c.png')];

    test('returns everything with no query and subfolders on', () {
      final result = filterPickerFiles(
        files,
        query: '',
        includeSubfolders: true,
      );
      expect(result.length, 3);
    });

    test('drops nested files when subfolders are off', () {
      final result = filterPickerFiles(
        files,
        query: '',
        includeSubfolders: false,
      );
      expect(result.map((d) => d.name), ['a.jpg']);
    });

    test('matches the query case-insensitively', () {
      final result = filterPickerFiles(
        files,
        query: 'C.PNG',
        includeSubfolders: true,
      );
      expect(result.map((d) => d.name), ['c.png']);
    });
  });

  group('AppLock', () {
    setUp(AppLock.reset);
    tearDown(AppLock.reset);

    test('expires only after the grace period', () {
      var now = DateTime(2026, 1, 1, 12);
      AppLock.clock = () => now;

      AppLock.markPaused();
      now = now.add(const Duration(seconds: 30));
      expect(AppLock.takeExpired(), isFalse);

      AppLock.markPaused();
      now = now.add(AppLock.grace + const Duration(seconds: 1));
      expect(AppLock.takeExpired(), isTrue);
      expect(AppLock.takeExpired(), isFalse);
    });

    test('does not arm while an external picker is open', () async {
      var now = DateTime(2026, 1, 1, 12);
      AppLock.clock = () => now;

      await AppLock.guardExternal(() async {
        AppLock.markPaused();
        now = now.add(const Duration(minutes: 5));
        expect(AppLock.takeExpired(), isFalse);
      });
    });

    test('arms again once the guard has finished', () async {
      var now = DateTime(2026, 1, 1, 12);
      AppLock.clock = () => now;

      await AppLock.guardExternal(() async {});
      AppLock.markPaused();
      now = now.add(AppLock.grace);
      expect(AppLock.takeExpired(), isTrue);
    });
  });
}
