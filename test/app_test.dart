import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:origin_scan/core/project_store.dart';
import 'package:origin_scan/ui/app.dart';

void main() {
  late Directory root;
  late ProjectStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('origin-widget-');
    store = ProjectStore(root);
    await store.init();
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  testWidgets(
    'Offline launch has no fabricated scans; import remains available without sensors',
    (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(OriginApp(store: store));
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pumpAndSettle();
      expect(find.text('ORIGIN Scan'), findsOneWidget);
      expect(find.text('Ready for the field.'), findsWidgets);
      await tester.tap(find.text('New Scan'));
      await tester.pumpAndSettle();
      expect(find.text('Scan with Device'), findsOneWidget);
      expect(find.text('Import Existing Scan'), findsOneWidget);
      expect(find.textContaining('Device scanning requires'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();
      expect(find.text('Keep raw capture data'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
