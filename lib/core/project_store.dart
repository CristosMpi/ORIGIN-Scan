import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:path/path.dart' as path;

import 'formats.dart';
import 'geometry.dart';

String newId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${List.generate(8, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

Future<void> atomicBytes(File file, List<int> bytes) async {
  await file.parent.create(recursive: true);
  final temp = File('${file.path}.tmp');
  final handle = await temp.open(mode: FileMode.write);
  try {
    await handle.writeFrom(bytes);
    await handle.flush();
  } finally {
    await handle.close();
  }
  // Keep the previous manifest if the process dies during replacement (Windows).
  final backup = File('${file.path}.bak');
  if (await file.exists()) {
    if (await backup.exists()) await backup.delete();
    await file.rename(backup.path);
  }
  await temp.rename(file.path);
  if (await backup.exists()) await backup.delete();
}

Future<Map<String, dynamic>> readJson(File file) async {
  for (final candidate in [file, File('${file.path}.bak')]) {
    if (!await candidate.exists()) continue;
    try {
      return jsonDecode(await candidate.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      /* Try a completed backup. */
    }
  }
  throw const FormatException('No valid local metadata file.');
}

class ScanProject {
  final String id, name, source, revision;
  final DateTime created;
  final int points, triangles, bytes;
  final bool saved;
  final Map<String, dynamic> quality;
  final Bounds bounds;
  ScanProject({
    required this.id,
    required this.name,
    required this.source,
    required this.revision,
    required this.created,
    required this.points,
    required this.triangles,
    required this.bytes,
    required this.saved,
    required this.bounds,
    this.quality = const {},
  });
  Map<String, dynamic> toJson() => {
    'schema': 1,
    'id': id,
    'name': name,
    'source': source,
    'revision': revision,
    'created': created.toUtc().toIso8601String(),
    'points': points,
    'triangles': triangles,
    'bytes': bytes,
    'saved': saved,
    'bounds': bounds.toJson(),
    'quality': quality,
    'units': 'metres',
    'coordinateSystem': 'right-handed Y-up; local session origin',
    'format': 'PLY',
  };
  factory ScanProject.fromJson(Map<String, dynamic> m) {
    Vec3 v(List list) => Vec3(
      (list[0] as num).toDouble(),
      (list[1] as num).toDouble(),
      (list[2] as num).toDouble(),
    );
    final id = m['id'] as String, revision = m['revision'] as String;
    if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(id) ||
        !RegExp(r'^[a-zA-Z0-9-]+\.ply$').hasMatch(revision)) {
      throw const FormatException('Invalid local project path.');
    }
    return ScanProject(
      id: id,
      name: m['name'] as String,
      source: m['source'] as String,
      revision: revision,
      created: DateTime.parse(m['created'] as String),
      points: m['points'] as int,
      triangles: m['triangles'] as int,
      bytes: m['bytes'] as int,
      saved: m['saved'] as bool,
      bounds: Bounds(
        v(m['bounds']['min'] as List),
        v(m['bounds']['max'] as List),
      ),
      quality: m['quality'] as Map<String, dynamic>? ?? {},
    );
  }
}

class AppSettings {
  ScanFormat exportFormat;
  String quality, units;
  bool retainRaw;
  AppSettings({
    this.exportFormat = ScanFormat.ply,
    this.quality = 'balanced',
    this.units = 'm',
    this.retainRaw = true,
  });
  Map<String, dynamic> toJson() => {
    'exportFormat': exportFormat.name,
    'quality': quality,
    'units': units,
    'retainRaw': retainRaw,
  };
  factory AppSettings.fromJson(Map<String, dynamic> m) => AppSettings(
    exportFormat:
        ScanFormat.values
            .where((f) => f.name == m['exportFormat'])
            .firstOrNull ??
        ScanFormat.ply,
    quality: ['balanced', 'detail', 'large'].contains(m['quality'])
        ? m['quality'] as String
        : 'balanced',
    units: m['units'] == 'cm' ? 'cm' : 'm',
    retainRaw: m['retainRaw'] as bool? ?? true,
  );
}

class ProjectStore {
  final Directory root;
  AppSettings settings = AppSettings();
  final List<String> warnings = [];
  ProjectStore(this.root);
  Directory get projects => Directory('${root.path}/projects');
  Directory get pending => Directory('${root.path}/pending');
  Directory folder(ScanProject p) => Directory('${projects.path}/${p.id}');
  File geometryFile(ScanProject p) => File('${folder(p).path}/${p.revision}');
  File thumbnail(ScanProject p) => File('${folder(p).path}/preview.png');
  Future<void> init() async {
    await projects.create(recursive: true);
    await pending.create(recursive: true);
    try {
      settings = AppSettings.fromJson(
        await readJson(File('${root.path}/settings.json')),
      );
    } catch (_) {
      /* First launch or corrupt preferences: safe defaults. */
    }
  }

  Future<void> saveSettings() => atomicBytes(
    File('${root.path}/settings.json'),
    utf8.encode(jsonEncode(settings.toJson())),
  );
  Future<List<ScanProject>> list() async {
    warnings.clear();
    final result = <ScanProject>[];
    await for (final entry in projects.list(followLinks: false)) {
      if (entry is! Directory) continue;
      try {
        final p = ScanProject.fromJson(
          await readJson(File('${entry.path}/project.json')),
        );
        if (entry.uri.pathSegments.where((s) => s.isNotEmpty).last != p.id ||
            !await geometryFile(p).exists()) {
          throw const FormatException('Missing geometry');
        }
        result.add(p);
      } catch (_) {
        warnings.add(
          'A project could not be opened: ${entry.path}. Its files have been kept.',
        );
      }
    }
    result.sort((a, b) => b.created.compareTo(a.created));
    return result;
  }

  Future<Geometry> load(ScanProject p) =>
      Isolate.run(() => importGeometry(geometryFile(p).path));
  Future<ScanProject> create(
    Geometry geometry, {
    required String name,
    required String source,
    Map<String, dynamic> quality = const {},
    String? originalPath,
    DateTime? capturedAt,
  }) async {
    final id = newId();
    // Directory name and manifest identity are the same; only completed manifests enter the library.
    final target = Directory('${projects.path}/$id');
    await target.create(recursive: true);
    final metadata = {
      'source': source,
      'units': 'metres',
      'coordinateSystem': 'right-handed Y-up',
    };
    final encoded = await Isolate.run(
      () => encodePly(geometry, metadata: metadata),
    );
    await atomicBytes(File('${target.path}/original.ply'), encoded);
    if (originalPath != null) {
      final ext = originalPath.split('.').last.toLowerCase();
      if (RegExp(r'^[a-z0-9]+$').hasMatch(ext)) {
        await File(originalPath).copy('${target.path}/imported-source.$ext');
      }
    }
    final p = ScanProject(
      id: id,
      name: cleanName(name),
      source: source,
      revision: 'original.ply',
      created: capturedAt ?? DateTime.now(),
      points: geometry.vertexCount,
      triangles: geometry.triangleCount,
      bytes: encoded.length,
      saved: false,
      bounds: geometry.bounds,
      quality: quality,
    );
    await _manifest(p);
    return p;
  }

  Future<void> _manifest(ScanProject p) => atomicBytes(
    File('${folder(p).path}/project.json'),
    utf8.encode(const JsonEncoder.withIndent('  ').convert(p.toJson())),
  );
  Future<ScanProject> save(
    ScanProject p,
    Geometry g, {
    required String name,
    bool edited = false,
  }) async {
    var revision = p.revision, bytes = p.bytes;
    if (edited) {
      revision = 'edit-${newId()}.ply';
      final data = await Isolate.run(() => encodePly(g, metadata: p.toJson()));
      await atomicBytes(File('${folder(p).path}/$revision'), data);
      bytes = data.length;
    }
    final next = ScanProject(
      id: p.id,
      name: cleanName(name),
      source: p.source,
      revision: revision,
      created: p.created,
      points: g.vertexCount,
      triangles: g.triangleCount,
      bytes: bytes,
      saved: true,
      bounds: g.bounds,
      quality: p.quality,
    );
    await _manifest(next);
    return next;
  }

  Future<ScanProject> rename(ScanProject p, String name) async {
    final m = p.toJson()..['name'] = cleanName(name);
    final next = ScanProject.fromJson(m);
    await _manifest(next);
    return next;
  }

  Future<ScanProject> duplicate(ScanProject p) async {
    final id = newId();
    final dir = Directory('${projects.path}/$id');
    await dir.create();
    // Copy provenance/raw data as well as the current and original geometry.
    final source = folder(p);
    await for (final entry in source.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = path.relative(entry.path, from: source.path);
      if (relative == 'project.json' ||
          relative.startsWith('preview-edit-') ||
          relative.endsWith('.tmp') ||
          relative.endsWith('.bak')) {
        continue;
      }
      final destination = path.join(dir.path, relative);
      if (entry is Directory) {
        await Directory(destination).create(recursive: true);
      } else if (entry is File) {
        await File(destination).parent.create(recursive: true);
        await entry.copy(destination);
      }
    }
    final m = p.toJson()
      ..['id'] = id
      ..['name'] = '${p.name} copy';
    final next = ScanProject.fromJson(m);
    await _manifest(next);
    return next;
  }

  Future<void> delete(ScanProject p) async {
    final target = folder(p).absolute;
    if (!path.equals(target.parent.path, projects.absolute.path) ||
        !RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(p.id)) {
      throw StateError('Invalid deletion path.');
    }
    if (await target.exists()) await target.delete(recursive: true);
  }

  Future<Directory> beginCapture(String source) async {
    final dir = Directory('${pending.path}/${newId()}');
    await dir.create();
    await atomicBytes(
      File('${dir.path}/session.json'),
      utf8.encode(
        jsonEncode({
          'schema': 1,
          'source': source,
          'started': DateTime.now().toUtc().toIso8601String(),
          'status': 'unfinished',
          'retainRaw': settings.retainRaw,
        }),
      ),
    );
    return dir;
  }

  Future<List<Directory>> recoverable() async {
    final dirs = <Directory>[];
    await for (final e in pending.list(followLinks: false)) {
      if (e is Directory &&
          await e.list().any((f) => f is File && f.path.endsWith('.ply'))) {
        dirs.add(e);
      }
    }
    return dirs;
  }

  Future<ScanProject> recover(Directory dir) async {
    if (!path.equals(dir.absolute.parent.path, pending.absolute.path)) {
      throw StateError('Invalid recovery path.');
    }
    final session = await readJson(File('${dir.path}/session.json'));
    final chunks = await dir
        .list()
        .where((f) => f is File && f.path.endsWith('.ply'))
        .map((f) => f.path)
        .toList();
    chunks.sort();
    final g = await Isolate.run(() async {
      final data = <Geometry>[];
      var count = 0;
      for (final path in chunks) {
        final part = await importGeometry(path);
        count += part.vertexCount;
        if (count > Geometry.maxVertices) {
          throw const FormatException(
            'Recovery exceeds the processing limit. Raw chunks are preserved.',
          );
        }
        data.add(part);
      }
      return Geometry.merge(data);
    });
    Map<String, dynamic> captureQuality = {};
    try {
      captureQuality = await readJson(File('${dir.path}/capture.json'));
    } catch (_) {
      /* Interrupted before final quality record. */
    }
    final p = await create(
      g,
      name: 'Field scan',
      source: session['source'] as String,
      capturedAt: DateTime.tryParse(session['started'] as String? ?? ''),
      quality: {
        ...captureQuality,
        'journalReassembled': true,
        'interrupted': captureQuality.isEmpty,
        'coverage': 'Not a completeness guarantee',
        if (session['started'] != null) 'captureStarted': session['started'],
      },
    );
    if (session['retainRaw'] as bool? ?? settings.retainRaw) {
      await dir.rename('${folder(p).path}/raw');
    } else {
      await dir.delete(recursive: true);
    }
    return p;
  }

  Future<int> storageBytes() async {
    var size = 0;
    await for (final f in root.list(recursive: true, followLinks: false)) {
      if (f is File) size += await f.length();
    }
    return size;
  }

  Future<File> prepareExport(
    ScanProject p,
    Geometry g,
    ScanFormat format,
  ) async {
    final dir = Directory('${root.path}/exports');
    await dir.create();
    final date = p.created.toLocal().toIso8601String().substring(0, 10);
    final safe = p.name.replaceAll(
      RegExp(r'[^\p{L}\p{N}_-]', unicode: true),
      '_',
    );
    final file = File('${dir.path}/ORIGIN_Scan_${safe}_$date.${format.name}');
    final metadata = p.toJson()
      ..['points'] = g.vertexCount
      ..['triangles'] = g.triangleCount
      ..['bounds'] = g.bounds.toJson()
      ..['format'] = format.label;
    final bytes = await Isolate.run(
      () => encodeGeometry(g, format, metadata: metadata),
    );
    await atomicBytes(file, bytes);
    // Every export gets a sidecar, including formats that cannot hold metadata (STL).
    await atomicBytes(
      File('${file.path}.json'),
      utf8.encode(const JsonEncoder.withIndent('  ').convert(metadata)),
    );
    // Validate structural output using the independent import path before offering it.
    await Isolate.run(() async {
      final check = await importGeometry(file.path);
      if (check.vertexCount == 0 ||
          (check.bounds.size - g.bounds.size).length > mathTolerance(g)) {
        throw const FormatException('Export verification failed.');
      }
    });
    return file;
  }
}

double mathTolerance(Geometry g) => .00001 * (g.bounds.size.length + 1);
String cleanName(String value) {
  final name = value.trim().replaceAll(RegExp(r'[\x00-\x1F]'), '');
  if (name.isEmpty) return 'Untitled scan';
  return name.length > 100 ? name.substring(0, 100) : name;
}
