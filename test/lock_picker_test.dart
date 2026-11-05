import 'package:curve_fault/services/lock_access.dart';
import 'package:curve_fault/services/native_storage.dart';
import 'package:curve_fault/widgets/lock_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

NativeDocument _doc(String name) {
  return NativeDocument(
    uri: 'content://picked/$name',
    name: name,
    mime: 'image/jpeg',
    size: 2048,
    relativePath: name,
    parentUri: '',
    lastModified: 0,
    isDirectory: false,
    canWrite: true,
  );
}

LockCandidate _ready(NativeDocument doc) {
  return LockCandidate(
    document: doc.withLocation(
      uri: 'content://tree/${doc.name}',
      relativePath: 'DCIM/${doc.name}',
    ),
    status: AccessStatus.ready,
    sourceUri: doc.uri,
  );
}

LockCandidate _needsAccess(NativeDocument doc) {
  return LockCandidate(
    document: doc,
    status: AccessStatus.needsAccess,
    sourceUri: doc.uri,
    folderKey: 'primary:Pictures/Shots',
    folderName: 'Shots',
  );
}

LockCandidate _unsupported(NativeDocument doc) {
  return LockCandidate(
    document: doc,
    status: AccessStatus.unsupported,
    sourceUri: doc.uri,
    reason: 'Cloud files cannot be locked in place',
  );
}

void main() {
  late bool called;
  late List<NativeDocument>? result;

  setUp(() {
    called = false;
    result = null;
  });

  Future<void> openSheet(
    WidgetTester tester, {
    required List<NativeDocument> picked,
    required AccessResolver resolve,
    AccessRequester? requestAccess,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await pickFilesToLock(
                    context,
                    pick: () async => picked,
                    resolve: resolve,
                    requestAccess: requestAccess,
                  );
                  called = true;
                },
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  testWidgets('ready files start checked and Add returns them', (tester) async {
    final a = _doc('a.jpg');
    final b = _doc('b.jpg');
    await openSheet(
      tester,
      picked: [a, b],
      resolve: (docs) async => docs.map(_ready).toList(),
    );

    expect(find.text('Select Files to Lock'), findsOneWidget);
    expect(find.text('a.jpg'), findsOneWidget);
    expect(find.text('b.jpg'), findsOneWidget);
    expect(find.text('Add 2'), findsOneWidget);

    await tester.tap(find.text('Add 2'));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(result!.map((d) => d.uri), [
      'content://tree/a.jpg',
      'content://tree/b.jpg',
    ]);
  });

  testWidgets('unchecking a file lowers the count', (tester) async {
    await openSheet(
      tester,
      picked: [_doc('a.jpg'), _doc('b.jpg')],
      resolve: (docs) async => docs.map(_ready).toList(),
    );

    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pump();

    expect(find.text('Add 1'), findsOneWidget);

    await tester.tap(find.text('Add 1'));
    await tester.pumpAndSettle();

    expect(result!.map((d) => d.name), ['b.jpg']);
  });

  testWidgets('files that need access are disabled and offer Allow access', (
    tester,
  ) async {
    final a = _doc('a.jpg');
    final b = _doc('b.jpg');
    await openSheet(
      tester,
      picked: [a, b],
      resolve: (docs) async => [_ready(a), _needsAccess(b)],
    );

    expect(find.text('Add 1'), findsOneWidget);
    expect(find.text('Allow access'), findsOneWidget);

    await tester.tap(find.byType(CheckboxListTile).last);
    await tester.pump();

    expect(find.text('Add 1'), findsOneWidget);
  });

  testWidgets('Allow access resolves again and enables the files', (
    tester,
  ) async {
    final b = _doc('b.jpg');
    var resolveCalls = 0;
    String? requestedFolder;

    await openSheet(
      tester,
      picked: [b],
      resolve: (docs) async {
        resolveCalls++;
        return resolveCalls == 1 ? [_needsAccess(b)] : [_ready(b)];
      },
      requestAccess: (folderKey) async {
        requestedFolder = folderKey;
        return true;
      },
    );

    expect(find.text('Select Files'), findsOneWidget);

    await tester.tap(find.text('Allow access'));
    await tester.pumpAndSettle();

    expect(requestedFolder, 'primary:Pictures/Shots');
    expect(resolveCalls, 2);
    expect(find.text('Add 1'), findsOneWidget);
    expect(find.text('Allow access'), findsNothing);
  });

  testWidgets('declining the folder keeps the files disabled', (tester) async {
    final b = _doc('b.jpg');
    var resolveCalls = 0;

    await openSheet(
      tester,
      picked: [b],
      resolve: (docs) async {
        resolveCalls++;
        return [_needsAccess(b)];
      },
      requestAccess: (folderKey) async => false,
    );

    await tester.tap(find.text('Allow access'));
    await tester.pumpAndSettle();

    expect(resolveCalls, 1);
    expect(find.text('Select Files'), findsOneWidget);
    expect(find.text('Allow access'), findsOneWidget);
  });

  testWidgets('unsupported files show their reason', (tester) async {
    final a = _doc('a.jpg');
    await openSheet(
      tester,
      picked: [a],
      resolve: (docs) async => [_unsupported(a)],
    );

    expect(find.textContaining('Cloud files cannot be locked in place'),
        findsWidgets);
    expect(find.text('Select Files'), findsOneWidget);
  });

  testWidgets('a cancelled picker returns null and opens no sheet', (
    tester,
  ) async {
    await openSheet(
      tester,
      picked: const [],
      resolve: (docs) async => const [],
    );

    expect(called, isTrue);
    expect(result, isNull);
    expect(find.text('Select Files to Lock'), findsNothing);
  });

  testWidgets('already locked files are skipped and reported', (tester) async {
    List<NativeDocument>? seen;
    await openSheet(
      tester,
      picked: [_doc('a.jpg'), _doc('old.cvlt')],
      resolve: (docs) async {
        seen = docs;
        return docs.map(_ready).toList();
      },
    );

    expect(seen!.map((d) => d.name), ['a.jpg']);
    expect(find.text('1 already locked file skipped'), findsOneWidget);
  });

  testWidgets('only locked files selected returns an empty list', (
    tester,
  ) async {
    await openSheet(
      tester,
      picked: [_doc('old.cvlt')],
      resolve: (docs) async => fail('nothing should be resolved'),
    );

    expect(called, isTrue);
    expect(result, isEmpty);
    expect(find.text('Select Files to Lock'), findsNothing);
  });
}
