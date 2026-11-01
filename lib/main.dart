import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'core/project_store.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final documents = await getApplicationDocumentsDirectory();
    final store = ProjectStore(Directory('${documents.path}/ORIGIN Scan'));
    await store.init();
    runApp(OriginApp(store: store));
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'ORIGIN Scan could not open local storage.\n$error\nFree some device storage and restart.',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
