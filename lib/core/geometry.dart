import 'dart:math' as math;
import 'dart:typed_data';

class Vec3 {
  final double x, y, z;
  const Vec3(this.x, this.y, this.z);
  Vec3 operator +(Vec3 b) => Vec3(x + b.x, y + b.y, z + b.z);
  Vec3 operator -(Vec3 b) => Vec3(x - b.x, y - b.y, z - b.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);
  double get length => math.sqrt(x * x + y * y + z * z);
  Vec3 cross(Vec3 b) =>
      Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x);
  List<double> toJson() => [x, y, z];
}

class Bounds {
  final Vec3 min, max;
  const Bounds(this.min, this.max);
  Vec3 get size => max - min;
  Vec3 get center => (min + max) * .5;
  bool contains(Vec3 p) =>
      p.x >= min.x &&
      p.x <= max.x &&
      p.y >= min.y &&
      p.y <= max.y &&
      p.z >= min.z &&
      p.z <= max.z;
  Map<String, dynamic> toJson() => {'min': min.toJson(), 'max': max.toJson()};
}

/// World coordinates are right handed, Y up, metres. No implicit normalization.
class Geometry {
  static const maxVertices = 5000000;
  static const maxTriangles = 10000000;
  final Float32List positions;
  final Uint32List indices;
  final Uint8List? colors;
  Geometry(this.positions, [Uint32List? indices, this.colors])
    : indices = indices ?? Uint32List(0) {
    if (positions.isEmpty ||
        positions.length % 3 != 0 ||
        vertexCount > maxVertices ||
        this.indices.length % 3 != 0 ||
        triangleCount > maxTriangles) {
      throw const FormatException(
        'Invalid or oversized geometry (limit: 5M vertices / 10M triangles).',
      );
    }
    for (final v in positions) {
      if (!v.isFinite || v.abs() > 1e8) {
        throw const FormatException('Geometry contains invalid coordinates.');
      }
    }
    for (final i in this.indices) {
      if (i >= vertexCount) {
        throw const FormatException('A face references a missing vertex.');
      }
    }
    if (colors != null && colors!.length != positions.length) {
      throw const FormatException('Invalid vertex colors.');
    }
  }
  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => indices.length ~/ 3;
  bool get hasMesh => indices.isNotEmpty;
  int get memoryBytes =>
      positions.lengthInBytes +
      indices.lengthInBytes +
      (colors?.lengthInBytes ?? 0);
  Vec3 point(int i) =>
      Vec3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]);
  late final Bounds bounds = _bounds();
  Bounds _bounds() {
    var lo = point(0), hi = lo;
    for (var i = 1; i < vertexCount; i++) {
      final p = point(i);
      lo = Vec3(math.min(lo.x, p.x), math.min(lo.y, p.y), math.min(lo.z, p.z));
      hi = Vec3(math.max(hi.x, p.x), math.max(hi.y, p.y), math.max(hi.z, p.z));
    }
    return Bounds(lo, hi);
  }

  Geometry scaled(double factor) {
    if (!factor.isFinite || factor <= 0) {
      throw const FormatException('Unit scale must be positive.');
    }
    return Geometry(
      Float32List.fromList(positions.map((p) => p * factor).toList()),
      indices,
      colors,
    );
  }

  static Geometry merge(List<Geometry> chunks) {
    if (chunks.isEmpty) {
      throw const FormatException(
        'There is no captured geometry to assemble. The local journal has been preserved.',
      );
    }
    final count = chunks.fold(0, (n, g) => n + g.vertexCount);
    final faces = chunks.fold(0, (n, g) => n + g.indices.length);
    if (count > maxVertices || faces > maxTriangles * 3) {
      throw const FormatException(
        'Scan exceeds the safe processing limit. Export smaller capture segments.',
      );
    }
    final p = Float32List(count * 3), t = Uint32List(faces);
    final c = chunks.every((g) => g.colors != null)
        ? Uint8List(count * 3)
        : null;
    var offset = 0, index = 0;
    for (final g in chunks) {
      p.setRange(offset * 3, offset * 3 + g.positions.length, g.positions);
      if (c != null) {
        c.setRange(offset * 3, offset * 3 + g.positions.length, g.colors!);
      }
      for (final i in g.indices) {
        t[index++] = i + offset;
      }
      offset += g.vertexCount;
    }
    return Geometry(p, t, c);
  }
}

Geometry selectVertices(Geometry g, bool Function(int) keep) {
  final remap = Int32List(g.vertexCount)..fillRange(0, g.vertexCount, -1);
  final vertices = <double>[], colors = <int>[], faces = <int>[];
  for (var i = 0; i < g.vertexCount; i++) {
    if (!keep(i)) continue;
    remap[i] = vertices.length ~/ 3;
    vertices.addAll(g.positions.getRange(i * 3, i * 3 + 3));
    if (g.colors != null) colors.addAll(g.colors!.getRange(i * 3, i * 3 + 3));
  }
  if (vertices.isEmpty) {
    throw const FormatException('This edit would remove every point.');
  }
  for (var i = 0; i < g.indices.length; i += 3) {
    final a = remap[g.indices[i]],
        b = remap[g.indices[i + 1]],
        c = remap[g.indices[i + 2]];
    if (a >= 0 && b >= 0 && c >= 0) faces.addAll([a, b, c]);
  }
  return Geometry(
    Float32List.fromList(vertices),
    Uint32List.fromList(faces),
    g.colors == null ? null : Uint8List.fromList(colors),
  );
}

Geometry crop(Geometry g, Bounds box) =>
    selectVertices(g, (i) => box.contains(g.point(i)));

String _cell(Vec3 p, double size) =>
    '${(p.x / size).floor()},${(p.y / size).floor()},${(p.z / size).floor()}';

/// Vertex clustering remaps existing faces; it never fabricates a surface.
Geometry voxelDownsample(Geometry g, double size) {
  if (!size.isFinite || size <= 0) {
    throw ArgumentError('Voxel size must be positive.');
  }
  final cells = <String, int>{}, p = <double>[], c = <int>[];
  final remap = Uint32List(g.vertexCount);
  for (var i = 0; i < g.vertexCount; i++) {
    final key = _cell(g.point(i), size);
    var n = cells[key];
    if (n == null) {
      n = p.length ~/ 3;
      cells[key] = n;
      p.addAll(g.positions.getRange(i * 3, i * 3 + 3));
      if (g.colors != null) c.addAll(g.colors!.getRange(i * 3, i * 3 + 3));
    }
    remap[i] = n;
  }
  final faces = <int>[];
  for (var i = 0; i < g.indices.length; i += 3) {
    final a = remap[g.indices[i]],
        b = remap[g.indices[i + 1]],
        c = remap[g.indices[i + 2]];
    if (a != b && b != c && a != c) faces.addAll([a, b, c]);
  }
  return Geometry(
    Float32List.fromList(p),
    Uint32List.fromList(faces),
    g.colors == null ? null : Uint8List.fromList(c),
  );
}

/// Radius-based outlier removal with bounded neighbor work per query.
Geometry removeIsolated(Geometry g, double radius, {int minimumNeighbors = 2}) {
  if (!radius.isFinite || radius <= 0) {
    throw ArgumentError('Radius must be positive.');
  }
  final cells = <String, List<int>>{};
  for (var i = 0; i < g.vertexCount; i++) {
    (cells[_cell(g.point(i), radius)] ??= []).add(i);
  }
  return selectVertices(g, (i) {
    final p = g.point(i),
        x = (p.x / radius).floor(),
        y = (p.y / radius).floor(),
        z = (p.z / radius).floor();
    var count = 0;
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (var dz = -1; dz <= 1; dz++) {
          for (final j
              in cells['${x + dx},${y + dy},${z + dz}'] ?? const <int>[]) {
            if (i != j &&
                (g.point(j) - p).length <= radius &&
                ++count >= minimumNeighbors) {
              return true;
            }
          }
        }
      }
    }
    return false;
  });
}

/// A conservative one-pass Laplacian edit. Boundary vertices remain fixed.
Geometry smoothMesh(Geometry g, {double strength = .15}) {
  if (!g.hasMesh) {
    throw const FormatException('Smoothing requires a triangle mesh.');
  }
  final sums = Float64List(g.positions.length),
      counts = Uint32List(g.vertexCount);
  final edgeCounts = <(int, int), int>{};
  for (var i = 0; i < g.indices.length; i += 3) {
    final face = [g.indices[i], g.indices[i + 1], g.indices[i + 2]];
    for (var k = 0; k < 3; k++) {
      final a = face[k], b = face[(k + 1) % 3], c = face[(k + 2) % 3];
      for (var axis = 0; axis < 3; axis++) {
        sums[a * 3 + axis] +=
            g.positions[b * 3 + axis] + g.positions[c * 3 + axis];
      }
      counts[a] += 2;
      final edge = a < b ? (a, b) : (b, a);
      edgeCounts[edge] = (edgeCounts[edge] ?? 0) + 1;
    }
  }
  final boundary = <int>{};
  for (final e in edgeCounts.entries) {
    if (e.value != 2) boundary.addAll([e.key.$1, e.key.$2]);
  }
  final out = Float32List.fromList(g.positions);
  for (var i = 0; i < g.vertexCount; i++) {
    if (counts[i] == 0 || boundary.contains(i)) continue;
    for (var a = 0; a < 3; a++) {
      out[i * 3 + a] +=
          (sums[i * 3 + a] / counts[i] - out[i * 3 + a]) * strength;
    }
  }
  return Geometry(out, g.indices, g.colors);
}

Float32List estimateMeshNormals(Geometry g) {
  final n = Float32List(g.positions.length);
  for (var i = 0; i < g.indices.length; i += 3) {
    final a = g.indices[i], b = g.indices[i + 1], c = g.indices[i + 2];
    final normal = (g.point(b) - g.point(a)).cross(g.point(c) - g.point(a));
    for (final v in [a, b, c]) {
      n[v * 3] += normal.x;
      n[v * 3 + 1] += normal.y;
      n[v * 3 + 2] += normal.z;
    }
  }
  for (var i = 0; i < n.length; i += 3) {
    final l = math.sqrt(
      n[i] * n[i] + n[i + 1] * n[i + 1] + n[i + 2] * n[i + 2],
    );
    if (l > 0) {
      n[i] /= l;
      n[i + 1] /= l;
      n[i + 2] /= l;
    } else {
      n[i + 1] = 1;
    }
  }
  return n;
}

/// Only isolated three-edge holes under a size limit; an explicit inferred edit.
Geometry fillSmallTriangularHoles(Geometry g, {double maximumEdge = .1}) {
  if (!g.hasMesh) {
    throw const FormatException('Hole filling requires an existing mesh.');
  }
  final edges = <(int, int), List<(int, int)>>{};
  final existing = <String>{};
  String faceKey(int a, int b, int c) => ([a, b, c]..sort()).join(',');
  for (var i = 0; i < g.indices.length; i += 3) {
    final f = [g.indices[i], g.indices[i + 1], g.indices[i + 2]];
    existing.add(faceKey(f[0], f[1], f[2]));
    for (var k = 0; k < 3; k++) {
      final a = f[k], b = f[(k + 1) % 3], key = a < b ? (a, b) : (b, a);
      (edges[key] ??= []).add((a, b));
    }
  }
  final next = <int, List<int>>{};
  for (final e in edges.values.where((v) => v.length == 1)) {
    (next[e.single.$1] ??= []).add(e.single.$2);
  }
  final added = <int>[];
  for (final a in next.keys) {
    if (next[a]!.length != 1) continue;
    final b = next[a]!.single;
    if (next[b]?.length != 1) continue;
    final c = next[b]!.single;
    if (next[c]?.length != 1 || next[c]!.single != a || {a, b, c}.length != 3) {
      continue;
    }
    final key = faceKey(a, b, c);
    if (existing.contains(key)) continue;
    if ((g.point(a) - g.point(b)).length > maximumEdge ||
        (g.point(b) - g.point(c)).length > maximumEdge ||
        (g.point(c) - g.point(a)).length > maximumEdge) {
      continue;
    }
    added.addAll([a, c, b]);
    existing.add(key);
  }
  if (added.isEmpty) {
    throw const FormatException(
      'No triangular boundary holes within 10 cm were found. Larger or ambiguous gaps are left open.',
    );
  }
  return Geometry(
    g.positions,
    Uint32List.fromList([...g.indices, ...added]),
    g.colors,
  );
}
