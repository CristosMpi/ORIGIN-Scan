import 'dart:isolate';
import 'dart:typed_data';

import 'formats.dart';
import 'geometry.dart';

// Only top-level worker entry points cross isolate boundaries. UI callbacks can
// capture an Element/State through a shared closure context and are unsendable.
Future<Geometry> loadGeometryJob(String path, {double unitScale = 1}) =>
    Isolate.run(() => importGeometry(path, unitScale: unitScale));

Future<Uint8List> encodePlyJob(Geometry geometry) =>
    Isolate.run(() => encodePly(geometry));

enum GeometryEdit { crop, removeIsolated, downsample, smooth, fillSmallHoles }

Future<Geometry> editGeometryJob(
  Geometry geometry,
  GeometryEdit operation, {
  Bounds? bounds,
  double parameter = .1,
}) => Isolate.run(() {
  return switch (operation) {
    GeometryEdit.crop => crop(geometry, bounds!),
    GeometryEdit.removeIsolated => removeIsolated(geometry, parameter),
    GeometryEdit.downsample => voxelDownsample(geometry, parameter),
    GeometryEdit.smooth => smoothMesh(geometry),
    GeometryEdit.fillSmallHoles => fillSmallTriangularHoles(
      geometry,
      maximumEdge: parameter,
    ),
  };
});
