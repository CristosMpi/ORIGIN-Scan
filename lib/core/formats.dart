import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as local_path;

import 'geometry.dart';

enum ScanFormat { ply, obj, glb, gltf, stl, xyz }

extension ScanFormatInfo on ScanFormat {
  String get label => name.toUpperCase();
  bool get requiresMesh => this == ScanFormat.obj || this == ScanFormat.stl;
}

const maxImportBytes = 256 * 1024 * 1024;

Future<Geometry> importGeometry(String path, {double unitScale = 1}) async {
  final file = File(path);
  if (await file.length() > maxImportBytes) {
    throw const FormatException(
      'File exceeds the 256 MB import limit. Split it into smaller sections first.',
    );
  }
  final bytes = await file.readAsBytes();
  final ext = path.split('.').last.toLowerCase();
  final Geometry g;
  switch (ext) {
    case 'ply':
      g = readPly(bytes);
    case 'obj':
      g = readObj(utf8.decode(bytes));
    case 'xyz':
      g = readXyz(utf8.decode(bytes));
    case 'stl':
      g = readStl(bytes);
    case 'glb':
    case 'gltf':
      g = await readGltf(bytes, File(path).parent, binary: ext == 'glb');
    default:
      throw FormatException(
        'Unsupported format .$ext. Use PLY, OBJ, GLB, GLTF, STL, or XYZ.',
      );
  }
  return unitScale == 1 ? g : g.scaled(unitScale);
}

class _Cursor {
  final ByteData data;
  int offset;
  final Endian endian;
  _Cursor(Uint8List bytes, this.offset, this.endian)
    : data = ByteData.sublistView(bytes);
  num scalar(String type) {
    final size = switch (type) {
      'char' || 'uchar' || 'int8' || 'uint8' => 1,
      'short' || 'ushort' || 'int16' || 'uint16' => 2,
      'int' || 'uint' || 'int32' || 'uint32' || 'float' || 'float32' => 4,
      'double' || 'float64' => 8,
      _ => throw FormatException('Unsupported PLY type: $type'),
    };
    if (offset + size > data.lengthInBytes) {
      throw const FormatException('Truncated binary data.');
    }
    final n = switch (type) {
      'char' || 'int8' => data.getInt8(offset),
      'uchar' || 'uint8' => data.getUint8(offset),
      'short' || 'int16' => data.getInt16(offset, endian),
      'ushort' || 'uint16' => data.getUint16(offset, endian),
      'int' || 'int32' => data.getInt32(offset, endian),
      'uint' || 'uint32' => data.getUint32(offset, endian),
      'float' || 'float32' => data.getFloat32(offset, endian),
      _ => data.getFloat64(offset, endian),
    };
    offset += size;
    return n;
  }
}

Geometry readPly(Uint8List bytes) {
  var end = -1;
  // Headers are small; never decode binary payload as text.
  for (var i = 0; i < math.min(bytes.length - 10, 65536); i++) {
    if (bytes[i] == 101 &&
        ascii.decode(bytes.sublist(i, i + 10), allowInvalid: true) ==
            'end_header' &&
        (i == 0 || bytes[i - 1] == 10)) {
      var j = i + 10;
      if (j < bytes.length && bytes[j] == 13) j++;
      if (j >= bytes.length || bytes[j] != 10) continue;
      end = j + 1;
      break;
    }
  }
  if (end < 0) throw const FormatException('Missing PLY header.');
  final lines = ascii
      .decode(bytes.sublist(0, end))
      .split('\n')
      .map((l) => l.trim())
      .toList();
  if (lines.first != 'ply') throw const FormatException('Invalid PLY magic.');
  final elements = <({String name, int count, List<List<String>> props})>[];
  var format = '';
  for (final line in lines.skip(1)) {
    final t = line.split(RegExp(r'\s+'));
    if (t[0] == 'format' && t.length >= 3) {
      format = t[1];
    }
    if (t[0] == 'element' && t.length == 3) {
      final n = int.parse(t[2]);
      if (n < 0 || n > Geometry.maxTriangles) {
        throw const FormatException('PLY element limit exceeded.');
      }
      elements.add((name: t[1], count: n, props: []));
    }
    if (t[0] == 'property') {
      if (elements.isEmpty) {
        throw const FormatException('PLY property has no element.');
      }
      elements.last.props.add(t.sublist(1));
    }
  }
  if (![
    'ascii',
    'binary_little_endian',
    'binary_big_endian',
  ].contains(format)) {
    throw const FormatException('Unsupported PLY encoding.');
  }
  final cursor = _Cursor(
    bytes,
    end,
    format == 'binary_big_endian' ? Endian.big : Endian.little,
  );
  final tokens = format == 'ascii'
      ? RegExp(r'\S+')
            .allMatches(ascii.decode(bytes.sublist(end)))
            .map((m) => m[0]!)
            .iterator
      : null;
  num read(String type) {
    if (tokens == null) return cursor.scalar(type);
    if (!tokens.moveNext()) throw const FormatException('Truncated ASCII PLY.');
    return num.parse(tokens.current);
  }

  Float32List? points;
  Uint8List? colors;
  final faces = <int>[];
  for (final e in elements) {
    if (e.name == 'vertex') {
      if (points != null || e.count > Geometry.maxVertices) {
        throw const FormatException('Invalid PLY vertex count.');
      }
      final names = e.props.map((p) => p.last).toSet();
      if (!names.containsAll(['x', 'y', 'z'])) {
        throw const FormatException('PLY vertices require x, y, z.');
      }
      points = Float32List(e.count * 3);
      if (names.containsAll(['red', 'green', 'blue'])) {
        colors = Uint8List(e.count * 3);
      }
    }
    for (var i = 0; i < e.count; i++) {
      for (final prop in e.props) {
        if (prop.first == 'list') {
          if (prop.length != 4) {
            throw const FormatException('Malformed PLY list.');
          }
          final count = read(prop[1]).toInt();
          if (count < 0 || count > 4096) {
            throw const FormatException('Oversized PLY list.');
          }
          final list = List<int>.generate(count, (_) => read(prop[2]).toInt());
          if (e.name == 'face' &&
              (prop.last == 'vertex_indices' || prop.last == 'vertex_index')) {
            for (var k = 1; k + 1 < list.length; k++) {
              faces.addAll([list[0], list[k], list[k + 1]]);
            }
            if (faces.length > Geometry.maxTriangles * 3) {
              throw const FormatException('Too many faces.');
            }
          }
        } else {
          if (prop.length != 2) {
            throw const FormatException('Malformed PLY property.');
          }
          final value = read(prop.first);
          if (e.name == 'vertex') {
            final a = ['x', 'y', 'z'].indexOf(prop.last);
            if (a >= 0) points![i * 3 + a] = value.toDouble();
            final c = ['red', 'green', 'blue'].indexOf(prop.last);
            if (c >= 0 && colors != null) {
              colors[i * 3 + c] = value.toInt().clamp(0, 255);
            }
          }
        }
      }
    }
  }
  if (points == null) throw const FormatException('PLY has no vertices.');
  return Geometry(points, Uint32List.fromList(faces), colors);
}

Geometry readObj(String text) {
  final p = <double>[], faces = <int>[];
  for (final line in const LineSplitter().convert(text)) {
    final t = line.split('#').first.trim().split(RegExp(r'\s+'));
    if (t.first == 'v' && t.length >= 4) {
      p.addAll(t.sublist(1, 4).map(double.parse));
      if (p.length > Geometry.maxVertices * 3) {
        throw const FormatException('Too many OBJ vertices.');
      }
    } else if (t.first == 'f' && t.length >= 4) {
      final f = t.skip(1).map((s) {
        final i = int.parse(s.split('/').first);
        final v = i < 0 ? p.length ~/ 3 + i : i - 1;
        if (v < 0) throw const FormatException('Invalid OBJ index.');
        return v;
      }).toList();
      for (var i = 1; i + 1 < f.length; i++) {
        faces.addAll([f[0], f[i], f[i + 1]]);
      }
      if (faces.length > Geometry.maxTriangles * 3) {
        throw const FormatException('Too many OBJ faces.');
      }
    }
  }
  return Geometry(Float32List.fromList(p), Uint32List.fromList(faces));
}

Geometry readXyz(String text) {
  final p = <double>[];
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final t = trimmed.split(RegExp(r'[\s,;]+'));
    if (t.length < 3) {
      throw const FormatException('XYZ requires three coordinates per row.');
    }
    p.addAll(t.take(3).map(double.parse));
    if (p.length > Geometry.maxVertices * 3) {
      throw const FormatException('Too many XYZ points.');
    }
  }
  return Geometry(Float32List.fromList(p));
}

Geometry readStl(Uint8List bytes) {
  final p = <double>[];
  if (bytes.length >= 84) {
    final data = ByteData.sublistView(bytes),
        count = ByteData.sublistView(bytes).getUint32(80, Endian.little);
    if (84 + count * 50 == bytes.length) {
      if (count * 3 > Geometry.maxVertices) {
        throw const FormatException('STL exceeds the vertex limit.');
      }
      for (var i = 0; i < count; i++) {
        for (var j = 0; j < 9; j++) {
          p.add(data.getFloat32(84 + i * 50 + 12 + j * 4, Endian.little));
        }
      }
      return Geometry(
        Float32List.fromList(p),
        Uint32List.fromList(List.generate(p.length ~/ 3, (i) => i)),
      );
    }
  }
  final text = ascii.decode(bytes);
  for (final match in RegExp(
    r'\bvertex\s+([^\s]+)\s+([^\s]+)\s+([^\s]+)',
  ).allMatches(text)) {
    p.addAll([
      double.parse(match[1]!),
      double.parse(match[2]!),
      double.parse(match[3]!),
    ]);
    if (p.length > Geometry.maxVertices * 3) {
      throw const FormatException('STL exceeds the vertex limit.');
    }
  }
  if (p.length % 9 != 0) {
    throw const FormatException('Incomplete STL triangle.');
  }
  return Geometry(
    Float32List.fromList(p),
    Uint32List.fromList(List.generate(p.length ~/ 3, (i) => i)),
  );
}

Future<Geometry> readGltf(
  Uint8List bytes,
  Directory directory, {
  required bool binary,
}) async {
  Uint8List? bin;
  late Map<String, dynamic> doc;
  if (binary) {
    final d = ByteData.sublistView(bytes);
    if (bytes.length < 20 ||
        d.getUint32(0, Endian.little) != 0x46546c67 ||
        d.getUint32(4, Endian.little) != 2 ||
        d.getUint32(8, Endian.little) != bytes.length) {
      throw const FormatException('Invalid GLB 2.0 file.');
    }
    var off = 12;
    Map<String, dynamic>? parsed;
    while (off + 8 <= bytes.length) {
      final n = d.getUint32(off, Endian.little),
          type = d.getUint32(off + 4, Endian.little);
      off += 8;
      if (n % 4 != 0 || off + n > bytes.length) {
        throw const FormatException('Invalid GLB chunk.');
      }
      final chunk = Uint8List.sublistView(bytes, off, off + n);
      if (type == 0x4e4f534a) {
        parsed = jsonDecode(utf8.decode(chunk)) as Map<String, dynamic>;
      }
      if (type == 0x004e4942) bin = chunk;
      off += n;
    }
    if (parsed == null || off != bytes.length) {
      throw const FormatException('GLB is missing its scene.');
    }
    doc = parsed;
  } else {
    doc = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }
  if (doc['asset']?['version'] != '2.0') {
    throw const FormatException('Only glTF 2.0 is supported.');
  }
  if ((doc['extensionsRequired'] as List? ?? []).isNotEmpty) {
    throw const FormatException(
      'Compressed or extended glTF is not supported. Export an uncompressed model.',
    );
  }
  if ((doc['skins'] as List? ?? []).isNotEmpty) {
    throw const FormatException(
      'Skinned glTF geometry is unsupported. Export static geometry.',
    );
  }
  final buffers = <Uint8List>[];
  var totalBytes = 0;
  for (final b in doc['buffers'] as List? ?? []) {
    final uri = b['uri'] as String?;
    late Uint8List data;
    if (uri == null) {
      if (bin == null) throw const FormatException('Missing GLB buffer.');
      data = bin;
    } else if (uri.startsWith('data:')) {
      final u = UriData.parse(uri);
      data = u.contentAsBytes();
    } else {
      final u = Uri.parse(uri);
      if (u.hasScheme ||
          u.hasAuthority ||
          u.path.startsWith('/') ||
          u.path.contains('\\') ||
          u.pathSegments.contains('..') ||
          u.query.isNotEmpty) {
        throw const FormatException(
          'Only sibling local glTF buffers are permitted.',
        );
      }
      final f = File(local_path.join(directory.path, u.path));
      final root = await directory.resolveSymbolicLinks();
      final resolved = await f.resolveSymbolicLinks();
      if (!local_path.isWithin(root, resolved)) {
        throw const FormatException(
          'glTF buffers must remain in the model folder.',
        );
      }
      if (await f.length() > maxImportBytes) {
        throw const FormatException('glTF buffer exceeds limit.');
      }
      data = await f.readAsBytes();
    }
    totalBytes += data.length;
    if (totalBytes > maxImportBytes || data.length < (b['byteLength'] as int)) {
      throw const FormatException('Invalid or oversized glTF buffer.');
    }
    buffers.add(data);
  }
  final views = doc['bufferViews'] as List? ?? [],
      accessors = doc['accessors'] as List? ?? [];
  List<num> accessor(int id, int width) {
    final a = accessors[id] as Map;
    if (a['sparse'] != null ||
        a['bufferView'] == null ||
        a['normalized'] == true) {
      throw const FormatException(
        'Sparse or normalized glTF accessors are unsupported.',
      );
    }
    if (a['type'] != (width == 3 ? 'VEC3' : 'SCALAR')) {
      throw const FormatException('Unexpected glTF accessor type.');
    }
    final v = views[a['bufferView']] as Map,
        count = a['count'] as int,
        type = a['componentType'] as int;
    if (count < 0 || count > Geometry.maxTriangles * 3) {
      throw const FormatException('glTF accessor limit exceeded.');
    }
    final size = switch (type) {
      5121 => 1,
      5123 => 2,
      5125 || 5126 => 4,
      _ => throw const FormatException('Unsupported glTF component.'),
    };
    if (width == 3 && type != 5126) {
      throw const FormatException('glTF positions must use float32.');
    }
    final stride = v['byteStride'] as int? ?? size * width;
    final offset =
        (v['byteOffset'] as int? ?? 0) + (a['byteOffset'] as int? ?? 0);
    final buffer = buffers[v['buffer'] as int],
        d = ByteData.sublistView(buffer);
    final viewEnd = (v['byteOffset'] as int? ?? 0) + (v['byteLength'] as int);
    if (offset < 0 ||
        stride < size * width ||
        (count > 0 &&
            offset + (count - 1) * stride + size * width >
                math.min(viewEnd, buffer.length))) {
      throw const FormatException('glTF accessor is outside its buffer.');
    }
    return List<num>.generate(count * width, (i) {
      final k = offset + (i ~/ width) * stride + (i % width) * size;
      return switch (type) {
        5121 => d.getUint8(k),
        5123 => d.getUint16(k, Endian.little),
        5125 => d.getUint32(k, Endian.little),
        _ => d.getFloat32(k, Endian.little),
      };
    });
  }

  List<double> identity() => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  List<double> multiply(List<double> a, List<double> b) =>
      List.generate(16, (i) {
        final row = i % 4, col = i ~/ 4;
        return List.generate(
          4,
          (k) => a[k * 4 + row] * b[col * 4 + k],
        ).reduce((a, b) => a + b);
      });
  List<double> transform(Map node) {
    if (node['matrix'] != null) {
      return (node['matrix'] as List)
          .map((v) => (v as num).toDouble())
          .toList();
    }
    final t = node['translation'] as List? ?? [0, 0, 0],
        s = node['scale'] as List? ?? [1, 1, 1],
        q = node['rotation'] as List? ?? [0, 0, 0, 1];
    final x = (q[0] as num).toDouble(),
        y = (q[1] as num).toDouble(),
        z = (q[2] as num).toDouble(),
        w = (q[3] as num).toDouble();
    return [
      (1 - 2 * (y * y + z * z)) * s[0],
      2 * (x * y + z * w) * s[0],
      2 * (x * z - y * w) * s[0],
      0.0,
      2 * (x * y - z * w) * s[1],
      (1 - 2 * (x * x + z * z)) * s[1],
      2 * (y * z + x * w) * s[1],
      0.0,
      2 * (x * z + y * w) * s[2],
      2 * (y * z - x * w) * s[2],
      (1 - 2 * (x * x + y * y)) * s[2],
      0.0,
      (t[0] as num).toDouble(),
      (t[1] as num).toDouble(),
      (t[2] as num).toDouble(),
      1.0,
    ].map((n) => (n as num).toDouble()).toList();
  }

  final chunks = <Geometry>[];
  final nodes = doc['nodes'] as List? ?? [],
      meshes = doc['meshes'] as List? ?? [];
  void visit(int id, List<double> parent, Set<int> stack) {
    if (stack.contains(id) || stack.length > 128) {
      throw const FormatException('Cyclic or excessive glTF scene hierarchy.');
    }
    final node = nodes[id] as Map,
        matrix = multiply(parent, transform(nodes[id] as Map));
    if (node['mesh'] != null) {
      for (final primitive in meshes[node['mesh']]['primitives'] as List) {
        if (primitive['targets'] != null) {
          throw const FormatException(
            'Morph targets are unsupported. Export static geometry.',
          );
        }
        final mode = primitive['mode'] as int? ?? 4;
        if (mode != 0 && mode != 4) {
          throw const FormatException(
            'Only glTF points and triangles are supported.',
          );
        }
        final p = accessor(primitive['attributes']['POSITION'] as int, 3);
        final out = Float32List(p.length);
        for (var i = 0; i < p.length; i += 3) {
          for (var r = 0; r < 3; r++) {
            out[i + r] =
                matrix[r] * p[i] +
                matrix[4 + r] * p[i + 1] +
                matrix[8 + r] * p[i + 2] +
                matrix[12 + r];
          }
        }
        final indices = mode == 0
            ? Uint32List(0)
            : Uint32List.fromList(
                primitive['indices'] == null
                    ? List.generate(p.length ~/ 3, (i) => i)
                    : accessor(
                        primitive['indices'] as int,
                        1,
                      ).map((n) => n.toInt()).toList(),
              );
        // A reflected transform reverses face winding.
        final det = Vec3(
          matrix[0],
          matrix[1],
          matrix[2],
        ).cross(Vec3(matrix[4], matrix[5], matrix[6]));
        if (det.x * matrix[8] + det.y * matrix[9] + det.z * matrix[10] < 0) {
          for (var i = 0; i + 2 < indices.length; i += 3) {
            final b = indices[i + 1];
            indices[i + 1] = indices[i + 2];
            indices[i + 2] = b;
          }
        }
        chunks.add(Geometry(out, indices));
      }
    }
    for (final child in node['children'] as List? ?? []) {
      visit(child as int, matrix, {...stack, id});
    }
  }

  final scenes = doc['scenes'] as List? ?? [];
  final roots = scenes.isEmpty
      ? List<int>.generate(nodes.length, (i) => i)
            .where(
              (i) =>
                  !nodes.any((n) => (n['children'] as List? ?? []).contains(i)),
            )
            .toList()
      : scenes[doc['scene'] as int? ?? 0]['nodes'] as List? ?? [];
  for (final root in roots) {
    visit(root as int, identity(), {});
  }
  return Geometry.merge(chunks);
}

Uint8List encodePly(Geometry g, {Map<String, dynamic> metadata = const {}}) {
  final header = ascii.encode(
    'ply\nformat binary_little_endian 1.0\ncomment ORIGIN Scan; units=metres; right-handed Y-up\ncomment ${jsonEncode(metadata).replaceAll(RegExp(r'[^\x20-\x7E]'), '?')}\nelement vertex ${g.vertexCount}\nproperty float x\nproperty float y\nproperty float z\n${g.colors == null ? '' : 'property uchar red\nproperty uchar green\nproperty uchar blue\n'}element face ${g.triangleCount}\nproperty list uchar uint vertex_indices\nend_header\n',
  );
  final stride = g.colors == null ? 12 : 15;
  final out = Uint8List(
    header.length + g.vertexCount * stride + g.triangleCount * 13,
  )..setRange(0, header.length, header);
  final data = ByteData.sublistView(out);
  var off = header.length;
  for (var i = 0; i < g.vertexCount; i++) {
    for (var j = 0; j < 3; j++) {
      data.setFloat32(off, g.positions[i * 3 + j], Endian.little);
      off += 4;
    }
    if (g.colors != null) {
      out.setRange(off, off + 3, g.colors!, i * 3);
      off += 3;
    }
  }
  for (var i = 0; i < g.indices.length; i += 3) {
    data.setUint8(off++, 3);
    for (var j = 0; j < 3; j++) {
      data.setUint32(off, g.indices[i + j], Endian.little);
      off += 4;
    }
  }
  return out;
}

Uint8List encodeGeometry(
  Geometry g,
  ScanFormat format, {
  Map<String, dynamic> metadata = const {},
}) {
  if (format.requiresMesh && !g.hasMesh) {
    throw FormatException(
      '${format.label} requires a mesh. Export this point cloud as PLY, GLB, GLTF, or XYZ.',
    );
  }
  if (format == ScanFormat.ply) return encodePly(g, metadata: metadata);
  if (format == ScanFormat.glb || format == ScanFormat.gltf) {
    return _encodeGltf(g, metadata, binary: format == ScanFormat.glb);
  }
  if (format == ScanFormat.stl) {
    final bytes = Uint8List(84 + g.triangleCount * 50),
        d = ByteData(84 + g.triangleCount * 50);
    d.setUint32(80, g.triangleCount, Endian.little);
    for (var i = 0; i < g.triangleCount; i++) {
      final a = g.point(g.indices[i * 3]),
          b = g.point(g.indices[i * 3 + 1]),
          c = g.point(g.indices[i * 3 + 2]);
      final n = (b - a).cross(c - a),
          normal = n.length > 0 ? n * (1 / n.length) : const Vec3(0, 0, 0);
      final values = [
        ...normal.toJson(),
        ...a.toJson(),
        ...b.toJson(),
        ...c.toJson(),
      ];
      for (var k = 0; k < 12; k++) {
        d.setFloat32(84 + i * 50 + k * 4, values[k], Endian.little);
      }
    }
    bytes.setAll(0, d.buffer.asUint8List());
    final header = ascii.encode('ORIGIN Scan | metres | right-handed Y-up');
    bytes.setRange(0, header.length, header);
    return bytes;
  }
  final text = StringBuffer(
    '# ORIGIN Scan | units: metres | right-handed Y-up\n# ${jsonEncode(metadata)}\n',
  );
  for (var i = 0; i < g.vertexCount; i++) {
    text.writeln(
      '${format == ScanFormat.obj ? 'v ' : ''}${g.point(i).toJson().map((n) => n.toStringAsPrecision(9)).join(' ')}',
    );
  }
  if (format == ScanFormat.obj) {
    for (var i = 0; i < g.indices.length; i += 3) {
      text.writeln(
        'f ${g.indices[i] + 1} ${g.indices[i + 1] + 1} ${g.indices[i + 2] + 1}',
      );
    }
  }
  return Uint8List.fromList(utf8.encode(text.toString()));
}

Uint8List _encodeGltf(
  Geometry g,
  Map<String, dynamic> metadata, {
  required bool binary,
}) {
  final normals = g.hasMesh ? estimateMeshNormals(g) : null;
  final pBytes = g.positions.length * 4,
      nBytes = normals?.lengthInBytes ?? 0,
      iBytes = g.indices.length * 4;
  final buffer = Uint8List(pBytes + nBytes + iBytes),
      d = ByteData.sublistView(buffer);
  for (var i = 0; i < g.positions.length; i++) {
    d.setFloat32(i * 4, g.positions[i], Endian.little);
  }
  if (normals != null) {
    for (var i = 0; i < normals.length; i++) {
      d.setFloat32(pBytes + i * 4, normals[i], Endian.little);
    }
  }
  for (var i = 0; i < g.indices.length; i++) {
    d.setUint32(pBytes + nBytes + i * 4, g.indices[i], Endian.little);
  }
  final doc = <String, dynamic>{
    'asset': {'version': '2.0', 'generator': 'ORIGIN Scan'},
    'extras': {
      'units': 'metres',
      'coordinateSystem': 'right-handed Y-up',
      ...metadata,
    },
    'scene': 0,
    'scenes': [
      {
        'nodes': [0],
      },
    ],
    'nodes': [
      {'mesh': 0},
    ],
    'buffers': [
      {
        'byteLength': buffer.length,
        if (!binary)
          'uri': 'data:application/octet-stream;base64,${base64Encode(buffer)}',
      },
    ],
    'bufferViews': [
      {'buffer': 0, 'byteOffset': 0, 'byteLength': pBytes, 'target': 34962},
      if (g.hasMesh)
        {
          'buffer': 0,
          'byteOffset': pBytes,
          'byteLength': nBytes,
          'target': 34962,
        },
      if (g.hasMesh)
        {
          'buffer': 0,
          'byteOffset': pBytes + nBytes,
          'byteLength': iBytes,
          'target': 34963,
        },
    ],
    'accessors': [
      {
        'bufferView': 0,
        'componentType': 5126,
        'count': g.vertexCount,
        'type': 'VEC3',
        'min': g.bounds.min.toJson(),
        'max': g.bounds.max.toJson(),
      },
      if (g.hasMesh)
        {
          'bufferView': 1,
          'componentType': 5126,
          'count': g.vertexCount,
          'type': 'VEC3',
        },
      if (g.hasMesh)
        {
          'bufferView': 2,
          'componentType': 5125,
          'count': g.indices.length,
          'type': 'SCALAR',
        },
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {'POSITION': 0, if (g.hasMesh) 'NORMAL': 1},
            if (g.hasMesh) 'indices': 2,
            'mode': g.hasMesh ? 4 : 0,
          },
        ],
      },
    ],
  };
  final json = utf8.encode(jsonEncode(doc));
  if (!binary) return Uint8List.fromList(json);
  final jsonSize = (json.length + 3) & ~3, binSize = (buffer.length + 3) & ~3;
  final out = Uint8List(12 + 8 + jsonSize + 8 + binSize),
      header = ByteData.sublistView(out);
  header.setUint32(0, 0x46546c67, Endian.little);
  header.setUint32(4, 2, Endian.little);
  header.setUint32(8, out.length, Endian.little);
  header.setUint32(12, jsonSize, Endian.little);
  header.setUint32(16, 0x4e4f534a, Endian.little);
  out.fillRange(20, 20 + jsonSize, 32);
  out.setRange(20, 20 + json.length, json);
  header.setUint32(20 + jsonSize, binSize, Endian.little);
  header.setUint32(24 + jsonSize, 0x004e4942, Endian.little);
  out.setRange(28 + jsonSize, 28 + jsonSize + buffer.length, buffer);
  return out;
}
