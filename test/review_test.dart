import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:origin_scan/core/geometry.dart';
import 'package:origin_scan/core/project_store.dart';
import 'package:origin_scan/ui/review_screen.dart';

void main() {
  late Directory root;
  late ProjectStore store;
  late ScanProject project;
  final points = Geometry(
    Float32List.fromList([0, 0, 0, .001, 0, 0, 0, 1, 0, 1, 0, 0]),
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('origin-review-');
    store = ProjectStore(root);
    await store.init();
    project = await store.create(
      points,
      name: 'Isolate regression',
      source: 'Explicit test fixture',
    );
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  testWidgets(
    'An edit launched from live UI runs in an isolate and saves/reopens',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: ReviewScreen(store: store, project: project, geometry: points),
        ),
      );
      await tester.ensureVisible(find.text('Downsample'));
      await tester.tap(find.text('Downsample'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2 cm'));
      await tester.pump();
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
      }
      await tester.pumpAndSettle();
      expect(find.text('Unable to complete'), findsNothing);
      await tester.tap(find.text('Save Scan'));
      await tester.pump();
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
      }
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final saved = (await store.list()).single;
        expect(saved.saved, true);
        expect((await store.load(saved)).vertexCount, 3);
      });
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
