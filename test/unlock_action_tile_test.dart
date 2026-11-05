import 'package:curve_fault/widgets/unlock_action_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> show(
    WidgetTester tester, {
    required bool loading,
    VoidCallback? onTap,
    bool dim = false,
    Widget? leading,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnlockActionTile(
            title: 'Unlock',
            titleSize: 20,
            loading: loading,
            dimWhenLoading: dim,
            leading: leading,
            onTap: onTap,
          ),
        ),
      ),
    );
  }

  testWidgets('idle tile shows the arrow and no spinner', (tester) async {
    await show(tester, loading: false, onTap: () {});

    expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('loading tile shows the spinner instead of the arrow', (
    tester,
  ) async {
    await show(tester, loading: true);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward), findsNothing);
  });

  testWidgets('tap calls onTap and a null onTap is inert', (tester) async {
    var taps = 0;
    await show(tester, loading: false, onTap: () => taps++);
    await tester.tap(find.text('Unlock'));
    expect(taps, 1);

    await show(tester, loading: false, onTap: null);
    await tester.tap(find.text('Unlock'));
    expect(taps, 1);
  });

  testWidgets('title dims only when asked to', (tester) async {
    Color? colorOf() =>
        tester.widget<Text>(find.text('Unlock')).style?.color;

    await show(tester, loading: true, dim: false);
    final normal = colorOf();

    await show(tester, loading: true, dim: true);
    expect(colorOf(), isNot(normal));
  });

  testWidgets('leading widget is rendered', (tester) async {
    await show(
      tester,
      loading: false,
      onTap: () {},
      leading: const Icon(Icons.fingerprint),
    );

    expect(find.byIcon(Icons.fingerprint), findsOneWidget);
  });
}
