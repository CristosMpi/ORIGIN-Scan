import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:origin_scan/core/geometry.dart';
import 'package:origin_scan/core/formats.dart';
import 'package:origin_scan/core/project_store.dart';

Geometry tetrahedron() => Geometry(
  Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]),
  Uint32List.fromList([0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]),
);

void main() {
  test(
    'Small triangular holes are opt-in and do not duplicate an existing face',
    () {
      final whole = tetrahedron().scaled(.01);
      final open = Geometry(
        whole.positions,
        Uint32List.fromList(whole.indices.sublist(0, 9)),
      );
      expect(fillSmallTriangularHoles(open).triangleCount, 4);
      expect(open.triangleCount, 3);
      final triangle = Geometry(
        Float32List.fromList([0, 0, 0, .01, 0, 0, 0, .01, 0]),
        Uint32List.fromList([0, 1, 2]),
      );
      expect(() => fillSmallTriangularHoles(triangle), throwsFormatException);
    },
  );
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('origin-test-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  test(
    'All six export formats round trip with metric extents and topology',
    () async {
      final g = tetrahedron();
      for (final f in ScanFormat.values) {
        final file = File('${temp.path}/metric.${f.name}');
        await file.writeAsBytes(encodeGeometry(g, f));
        final read = await importGeometry(file.path);
        expect(read.bounds.min.toJson(), [0, 0, 0], reason: f.name);
        expect(read.bounds.size.toJson(), [1, 1, 1], reason: f.name);
        if (f != ScanFormat.xyz) expect(read.triangleCount, 4, reason: f.name);
      }
    },
  );
  test(
    'Point clouds export honestly, mesh-only formats reject missing faces',
    () async {
      final g = Geometry(Float32List.fromList([0, 0, 0, 2, 3, 4]));
      for (final f in [
        ScanFormat.ply,
        ScanFormat.glb,
        ScanFormat.gltf,
        ScanFormat.xyz,
      ]) {
        final file = File('${temp.path}/points.${f.name}');
        await file.writeAsBytes(encodeGeometry(g, f));
        final result = await importGeometry(file.path);
        expect(result.vertexCount, 2);
        expect(result.hasMesh, false);
        expect(result.bounds.max.toJson(), [2, 3, 4]);
      }
      expect(() => encodeGeometry(g, ScanFormat.obj), throwsFormatException);
      expect(() => encodeGeometry(g, ScanFormat.stl), throwsFormatException);
    },
  );
  test('ASCII PLY triangulates polygons and retains colors in binary output', () {
    final text =
        'ply\nformat ascii 1.0\nelement vertex 4\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nelement face 1\nproperty list uchar int vertex_indices\nend_header\n0 0 0 255 0 0\n1 0 0 0 255 0\n1 1 0 0 0 255\n0 1 0 255 255 255\n4 0 1 2 3\n';
    final g = readPly(Uint8List.fromList(utf8.encode(text)));
    expect(g.triangleCount, 2);
    expect(readPly(encodePly(g)).colors, g.colors);
  });
  test(
    'PLY binary big endian scalar types and unknown properties are read',
    () {
      final h = utf8.encode(
        'ply\nformat binary_big_endian 1.0\nelement vertex 1\nproperty double x\nproperty double y\nproperty double z\nproperty ushort intensity\nend_header\n',
      );
      final d = ByteData(26)
        ..setFloat64(0, 1.25, Endian.big)
        ..setFloat64(8, -2.5, Endian.big)
        ..setFloat64(16, 3.75, Endian.big)
        ..setUint16(24, 400, Endian.big);
      final g = readPly(Uint8List.fromList([...h, ...d.buffer.asUint8List()]));
      expect(g.point(0).toJson(), [1.25, -2.5, 3.75]);
    },
  );
  test(
    'Malformed geometry, truncated input and index overflow are rejected',
    () {
      expect(
        () => Geometry(Float32List.fromList([double.nan, 0, 0])),
        throwsFormatException,
      );
      expect(
        () => Geometry(
          Float32List.fromList([0, 0, 0]),
          Uint32List.fromList([0, 1, 2]),
        ),
        throwsFormatException,
      );
      final bytes = encodePly(tetrahedron());
      expect(
        () => readPly(bytes.sublist(0, bytes.length - 1)),
        throwsFormatException,
      );
      expect(() => readObj('v 0 0 0\nf 0 1 1'), throwsFormatException);
    },
  );
  test('OBJ negative indices, units and STL normals survive import', () async {
    final obj = readObj('v 0 0 0\nv 100 0 0\nv 0 100 0\nf -3 -2 -1');
    expect(obj.scaled(.01).bounds.size.toJson(), [1, 1, 0]);
    expect(obj.indices, [0, 1, 2]);
    final file = File('${temp.path}/centimetres.obj');
    await file.writeAsString('v 0 0 0\nv 100 0 0\nv 0 100 0\nf 1 2 3');
    expect((await importGeometry(file.path, unitScale: .01)).bounds.size.x, 1);
  });
  test('glTF hierarchical transforms preserve metres and instancing', () async {
    final document = jsonDecode(
      utf8.decode(encodeGeometry(tetrahedron(), ScanFormat.gltf)),
    ) as Map<String, dynamic>;
    document['nodes'] = [
      {
        'translation': [10, 0, 0],
        'children': [1],
      },
      {
        'mesh': 0,
        'scale': [2, 2, 2],
      },
    ];
    final file = File('${temp.path}/transformed.gltf');
    await file.writeAsString(jsonEncode(document));
    final g = await importGeometry(file.path);
    expect(g.bounds.min.x, 10);
    expect(g.bounds.max.x, 12);
    expect(g.bounds.max.y, 2);
    document['nodes'] = [
      {
        'children': [0],
      },
    ];
    await file.writeAsString(jsonEncode(document));
    expect(importGeometry(file.path), throwsFormatException);
  });
  test('glTF rejects remote buffers and unsupported compression', () async {
    final d = jsonDecode(
      utf8.decode(encodeGeometry(tetrahedron(), ScanFormat.gltf)),
    ) as Map<String, dynamic>;
    d['buffers'][0]['uri'] = 'https://example.com/scan.bin';
    final f = File('${temp.path}/bad.gltf');
    await f.writeAsString(jsonEncode(d));
    await expectLater(importGeometry(f.path), throwsFormatException);
    d['extensionsRequired'] = ['KHR_draco_mesh_compression'];
    await f.writeAsString(jsonEncode(d));
    await expectLater(importGeometry(f.path), throwsFormatException);
  });
  test(
    'Crop and voxel edits remap faces without mutating original geometry',
    () {
      final g = tetrahedron();
      final cropped = crop(g, const Bounds(Vec3(-1, -1, -1), Vec3(1, 1, .5)));
      expect(cropped.vertexCount, 3);
      expect(cropped.triangleCount, 1);
      expect(g.vertexCount, 4);
      expect(g.bounds.max.z, 1);
      final down = voxelDownsample(g, 2);
      expect(down.vertexCount, 1);
      expect(down.triangleCount, 0);
      expect(
        () => crop(g, const Bounds(Vec3(5, 5, 5), Vec3(6, 6, 6))),
        throwsFormatException,
      );
    },
  );
  test(
    'Outlier removal uses distance, smoothing keeps mesh boundaries fixed',
    () {
      final g = Geometry(
        Float32List.fromList([0, 0, 0, .01, 0, 0, 0, .01, 0, 100, 100, 100]),
      );
      expect(removeIsolated(g, .03).vertexCount, 3);
      expect(g.vertexCount, 4);
      final triangle = Geometry(
        Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]),
        Uint32List.fromList([0, 1, 2]),
      );
      expect(smoothMesh(triangle).positions, triangle.positions);
      final normals = estimateMeshNormals(triangle);
      expect(normals, [0, 0, 1, 0, 0, 1, 0, 0, 1]);
    },
  );
  test(
    'Project save, edit, close, reopen, duplicate and delete preserve original',
    () async {
      final store = ProjectStore(temp);
      await store.init();
      final g = tetrahedron();
      var p = await store.create(g, name: 'Test site', source: 'Test fixture');
      expect((await store.list()).single.saved, false);
      p = await store.save(p, g.scaled(2), name: 'Site A', edited: true);
      final reopened = ProjectStore(temp);
      await reopened.init();
      final found = (await reopened.list()).single;
      expect(found.name, 'Site A');
      expect(found.saved, true);
      expect((await reopened.load(found)).bounds.max.x, 2);
      expect(
        (await importGeometry('${store.folder(p).path}/original.ply'))
            .bounds
            .max
            .x,
        1,
      );
      final duplicate = await reopened.duplicate(found);
      await reopened.delete(found);
      expect((await reopened.list()).single.id, duplicate.id);
      expect((await reopened.load(duplicate)).bounds.max.x, 2);
    },
  );
  test(
    'Interrupted journal is recovered without network or invented geometry',
    () async {
      final store = ProjectStore(temp);
      await store.init();
      final dir = await store.beginCapture('Real sensor journal');
      await File('${dir.path}/mesh-1.ply')
          .writeAsBytes(encodePly(tetrahedron()));
      expect(await store.recoverable(), hasLength(1));
      final p = await store.recover(dir);
      expect(p.source, 'Real sensor journal');
      expect(p.points, 4);
      expect(await store.recoverable(), isEmpty);
      expect(await Directory('${store.folder(p).path}/raw').exists(), true);
    },
  );
  test(
    'Manifest backup, malformed-project isolation and export metadata work',
    () async {
      final store = ProjectStore(temp);
      await store.init();
      final g = tetrahedron();
      final p = await store.create(
        g,
        name: 'Acropolis',
        source: 'Fixture import',
      );
      final manifest = File('${store.folder(p).path}/project.json');
      await manifest.rename('${manifest.path}.bak');
      expect(await store.list(), hasLength(1));
      final f = await store.prepareExport(p, g, ScanFormat.glb);
      final metadata = jsonDecode(await File('${f.path}.json').readAsString());
      expect(metadata['units'], 'metres');
      expect(metadata['source'], 'Fixture import');
      await Directory('${store.projects.path}/broken').create();
      expect(await store.list(), hasLength(1));
      expect(store.warnings, hasLength(1));
    },
  );
}
