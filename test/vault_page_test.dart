import 'package:curve_fault/models/vault_entry.dart';
import 'package:curve_fault/pages/vault_page.dart';
import 'package:curve_fault/services/vault_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

VaultEntry _entry(int n) {
  return VaultEntry(
    id: 'id$n',
    uri: 'content://x/$n',
    name: 'file$n.jpg',
    mime: 'image/jpeg',
    size: 1024 * n,
    relativePath: 'DCIM/file$n.jpg',
    addedAt: 1700000000000 + n,
  );
}

void main() {
  setUp(() {
    VaultService.instance.debugSetEntries([_entry(1), _entry(2), _entry(3)]);
  });

  tearDown(() {
    VaultService.instance.debugSetEntries(const []);
  });

  Future<void> pumpPage(WidgetTester tester) {
    return tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: false),
        home: const VaultPage(),
      ),
    );
  }

  testWidgets('rows have no per item overflow icon', (tester) async {
    await pumpPage(tester);

    expect(find.text('file1.jpg'), findsOneWidget);
    expect(find.text('file3.jpg'), findsOneWidget);
    // Only the header menu keeps its three dots.
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
  });

  testWidgets('file size sits on the right of each row', (tester) async {
    await pumpPage(tester);

    expect(find.text('1.0 KB'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.text('3.0 KB'), findsOneWidget);
  });

  testWidgets('long press offers select all and restore', (tester) async {
    await pumpPage(tester);

    await tester.longPress(find.text('file1.jpg'));
    await tester.pump();

    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byIcon(Icons.select_all), findsOneWidget);
    expect(find.byIcon(Icons.restore), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pump();

    expect(find.text('3 selected'), findsOneWidget);
  });

  testWidgets('select all toggles back to an empty selection', (tester) async {
    await pumpPage(tester);

    await tester.longPress(find.text('file2.jpg'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pump();

    expect(find.text('Vault'), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
  });
}
