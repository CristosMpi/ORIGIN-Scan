// Explicit synthetic metric fixtures for interoperability QA, never app assets.
import 'dart:io';
import 'dart:typed_data';

import 'package:origin_scan/core/formats.dart';
import 'package:origin_scan/core/geometry.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Pass a dedicated QA output directory.');
  }
  final dir = Directory(args.single);
  await dir.create(recursive: true);
  final g = Geometry(
    Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]),
    Uint32List.fromList([0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]),
  );
  for (final format in ScanFormat.values) {
    await File('${dir.path}/ORIGIN_QA_One_Metre.${format.name}').writeAsBytes(
      encodeGeometry(
        g,
        format,
        metadata: {
          'source': 'Synthetic QA fixture, not a sensor capture',
          'units': 'metres',
        },
      ),
    );
  }
}
