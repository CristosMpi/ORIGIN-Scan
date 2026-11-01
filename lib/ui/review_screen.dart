import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/formats.dart';
import '../core/geometry.dart';
import '../core/jobs.dart';
import '../core/project_store.dart';
import 'app.dart';
import 'viewer.dart';

class ReviewScreen extends StatefulWidget {
  final ProjectStore store;
  final ScanProject project;
  final Geometry geometry;
  const ReviewScreen({
    super.key,
    required this.store,
    required this.project,
    required this.geometry,
  });
  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late ScanProject project = widget.project;
  late Geometry geometry = widget.geometry;
  late String name = project.name,
      viewerPath = widget.store.geometryFile(project).path;
  bool edited = false;
  String? busy;
  String measurement = '';
  final undo = <Geometry>[];
  int revision = 0;
  Future<void> work(String label, Future<void> Function() action) async {
    setState(() => busy = label);
    try {
      await action();
    } catch (e) {
      if (mounted) await showError(context, e);
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  Future<void> edit(
    String title,
    GeometryEdit operation, {
    Bounds? bounds,
    double parameter = .1,
  }) => work(title, () async {
    final result = await editGeometryJob(
      geometry,
      operation,
      bounds: bounds,
      parameter: parameter,
    );
    final file = File(
      '${widget.store.folder(project).path}/preview-edit-${++revision}.ply',
    );
    await atomicBytes(file, await encodePlyJob(result));
    if (!mounted) return;
    setState(() {
      if (undo.length >= 3) undo.removeAt(0);
      undo.add(geometry);
      geometry = result;
      viewerPath = file.path;
      edited = true;
      measurement = '';
    });
  });
  Future<void> save() => work('Saving scan to this device…', () async {
    project = await widget.store.save(
      project,
      geometry,
      name: name,
      edited: edited,
    );
    await writeThumbnail(geometry, widget.store.thumbnail(project));
    if (mounted) {
      setState(() => edited = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Scan saved locally.'),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(20, 0, 20, 86),
          duration: Duration(seconds: 2),
        ),
      );
    }
  });
  Future<void> export() async {
    final format = await showDialog<ScanFormat>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Export geometry'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              'All exports use metres. Point-only models cannot be exported as OBJ or STL.',
              style: TextStyle(fontSize: 12, color: quiet, height: 1.5),
            ),
          ),
          ...ScanFormat.values.map(
            (f) => SimpleDialogOption(
              onPressed: f.requiresMesh && !geometry.hasMesh
                  ? null
                  : () => Navigator.pop(c, f),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '${f.label}${f.requiresMesh && !geometry.hasMesh ? ' · mesh required' : ''}${f == widget.store.settings.exportFormat ? '  • default' : ''}',
                  style: TextStyle(
                    color: f.requiresMesh && !geometry.hasMesh ? quiet : ink,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    if (format == null || !mounted) return;
    await work('Writing and validating ${format.label}…', () async {
      final exportProject = ScanProject.fromJson(
        project.toJson()..['name'] = cleanName(name),
      );
      final file = await widget.store.prepareExport(
        exportProject,
        geometry,
        format,
      );
      final bytes = await file.readAsBytes();
      final destination = await FilePicker.saveFile(
        dialogTitle: 'Save ${format.label} to Files',
        fileName: file.uri.pathSegments.last,
        bytes: bytes,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(
            destination == null ? 'Local export ready' : 'Export saved',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  destination == null
                      ? 'The file picker was closed. The validated export is still available locally:'
                      : Platform.isAndroid
                      ? 'Saved to the location selected in Android Files. A validated copy is also kept here:'
                      : 'Saved file:',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  Platform.isAndroid || destination == null
                      ? file.path
                      : destination.scheme == 'file'
                      ? destination.toFilePath()
                      : destination.toString(),
                ),
                const SizedBox(height: 16),
                Text(
                  'Metadata sidecar: ${file.path}.json\n\nSTL and XYZ have limited metadata support. Save the sidecar separately when you need capture provenance.',
                  style: const TextStyle(
                    fontSize: 12,
                    color: quiet,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                try {
                  await FilePicker.saveFile(
                    dialogTitle: 'Save metadata',
                    fileName: '${file.uri.pathSegments.last}.json',
                    bytes: await File('${file.path}.json').readAsBytes(),
                  );
                } catch (e) {
                  if (c.mounted) await showError(c, e);
                }
              },
              child: const Text('Save metadata'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    });
  }

  Future<bool> allowLeave() async {
    if (!edited && name == project.name) return true;
    return await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Keep your changes?'),
            content: const Text(
              'Save changes before leaving. The original scan is always preserved.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Discard edits'),
              ),
              FilledButton(
                onPressed: () async {
                  Navigator.pop(c, false);
                  await save();
                },
                child: const Text('Save Scan'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final size = geometry.bounds.size,
        factor = widget.store.settings.units == 'cm' ? 100.0 : 1.0,
        unit = widget.store.settings.units;
    return PopScope(
      canPop: busy == null && !edited && name == project.name,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && busy == null && await allowLeave() && mounted) {
          setState(() {
            edited = false;
            name = project.name;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.pop(context);
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Review scan'),
          actions: [
            IconButton(
              tooltip: 'Rename scan',
              onPressed: busy == null
                  ? () async {
                      final n = await nameDialog(context, name);
                      if (n != null && mounted) setState(() => name = n);
                    }
                  : null,
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
        body: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  flex: 6,
                  child: GeometryViewer(
                    key: ValueKey(viewerPath),
                    path: viewerPath,
                    geometry: geometry,
                    units: widget.store.settings.units,
                    onMeasurement: (m) => setState(() => measurement = m),
                  ),
                ),
                if (measurement.isNotEmpty)
                  Container(
                    width: double.infinity,
                    color: const Color(0xffe3e8dc),
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      measurement,
                      style: const TextStyle(fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),
                Expanded(
                  flex: 5,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            fontSize: 25,
                            letterSpacing: -.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${project.source} · ${shortDate(project.created)}',
                          style: const TextStyle(color: quiet, fontSize: 12),
                        ),
                        const SizedBox(height: 18),
                        Wrap(
                          spacing: 28,
                          runSpacing: 16,
                          children: [
                            stat('POINTS', geometry.vertexCount.toString()),
                            stat(
                              'TRIANGLES',
                              geometry.triangleCount.toString(),
                            ),
                            stat(
                              'GEOMETRY RAM',
                              formatBytes(geometry.memoryBytes),
                            ),
                            stat('SAVED FILE', formatBytes(project.bytes)),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '${(size.x * factor).toStringAsFixed(2)} × ${(size.y * factor).toStringAsFixed(2)} × ${(size.z * factor).toStringAsFixed(2)} $unit',
                          style: const TextStyle(fontSize: 15),
                        ),
                        const SizedBox(height: 5),
                        const Text(
                          'X × Y × Z · right-handed, Y up · local origin',
                          style: TextStyle(color: quiet, fontSize: 11),
                        ),
                        const Divider(height: 30),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            editButton(Icons.crop, 'Crop', () async {
                              final bounds = await cropDialog(
                                context,
                                geometry.bounds,
                              );
                              if (bounds != null) {
                                await edit(
                                  'Cropping geometry…',
                                  GeometryEdit.crop,
                                  bounds: bounds,
                                );
                              }
                            }),
                            editButton(
                              Icons.filter_alt_outlined,
                              'Clean',
                              () async {
                                final radius = await distanceDialog(
                                  context,
                                  'Remove isolated points',
                                  'Keep points with at least two neighbors in this radius.',
                                  [.02, .05, .1, .2],
                                );
                                if (radius != null) {
                                  await edit(
                                    'Removing isolated points…',
                                    GeometryEdit.removeIsolated,
                                    parameter: radius,
                                  );
                                }
                              },
                            ),
                            editButton(Icons.grain, 'Downsample', () async {
                              final size = await distanceDialog(
                                context,
                                'Voxel downsampling',
                                'Keep one vertex per voxel and remap existing faces.',
                                [.01, .02, .05, .1],
                              );
                              if (size != null) {
                                await edit(
                                  'Downsampling…',
                                  GeometryEdit.downsample,
                                  parameter: size,
                                );
                              }
                            }),
                            editButton(
                              Icons.blur_on,
                              'Smooth',
                              geometry.hasMesh
                                  ? () => edit(
                                      'Smoothing mesh…',
                                      GeometryEdit.smooth,
                                    )
                                  : null,
                            ),
                            editButton(
                              Icons.undo,
                              'Undo',
                              undo.isEmpty
                                  ? null
                                  : () => work('Restoring previous edit…', () async {
                                      final previous = undo.removeLast();
                                      final file = File(
                                        '${widget.store.folder(project).path}/preview-edit-${++revision}.ply',
                                      );
                                      await atomicBytes(
                                        file,
                                        await encodePlyJob(previous),
                                      );
                                      setState(() {
                                        geometry = previous;
                                        viewerPath = file.path;
                                        edited = true;
                                      });
                                    }),
                            ),
                            editButton(
                              Icons.restore,
                              'Original',
                              restoreOriginal,
                            ),
                            editButton(
                              Icons.polyline_outlined,
                              'Fill small holes',
                              geometry.hasMesh
                                  ? () async {
                                      final apply = await showDialog<bool>(
                                        context: context,
                                        builder: (c) => AlertDialog(
                                          title: const Text(
                                            'Infer small missing faces?',
                                          ),
                                          content: const Text(
                                            'Fill only triangular boundary holes with edges up to 10 cm. These new faces are inferred, not sensor observations. The original is preserved.',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(c, false),
                                              child: const Text('Cancel'),
                                            ),
                                            FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(c, true),
                                              child: const Text('Fill holes'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (apply == true) {
                                        await edit(
                                          'Filling small triangular holes…',
                                          GeometryEdit.fillSmallHoles,
                                        );
                                      }
                                    }
                                  : null,
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'Edits preserve the original. Coverage and survey accuracy cannot be inferred from point count.',
                          style: TextStyle(
                            fontSize: 11,
                            color: quiet,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 10),
                        SelectableText(
                          widget.store.folder(project).path,
                          style: const TextStyle(fontSize: 10, color: quiet),
                        ),
                      ],
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: busy == null ? save : null,
                            icon: const Icon(Icons.check, size: 18),
                            label: const Text('Save Scan'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: busy == null ? export : null,
                          icon: const Icon(
                            Icons.file_download_outlined,
                            size: 18,
                          ),
                          label: const Text('Export'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (busy != null)
              Positioned.fill(
                child: ColoredBox(
                  color: paper.withValues(alpha: .95),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(strokeWidth: 2),
                        const SizedBox(height: 18),
                        Text(busy!),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget stat(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(fontSize: 9, letterSpacing: 1, color: quiet),
      ),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(fontSize: 16)),
    ],
  );
  Widget editButton(IconData icon, String text, VoidCallback? action) =>
      OutlinedButton.icon(
        onPressed: busy == null ? action : null,
        icon: Icon(icon, size: 16),
        label: Text(text, style: const TextStyle(fontSize: 12)),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
      );
  Future<void> restoreOriginal() => work('Restoring original…', () async {
    final file = File('${widget.store.folder(project).path}/original.ply');
    final g = await loadGeometryJob(file.path);
    setState(() {
      if (undo.length >= 3) undo.removeAt(0);
      undo.add(geometry);
      geometry = g;
      viewerPath = file.path;
      edited = true;
    });
  });
}

Future<double?> distanceDialog(
  BuildContext context,
  String title,
  String detail,
  List<double> values,
) => showDialog<double>(
  context: context,
  builder: (c) => SimpleDialog(
    title: Text(title),
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: Text(detail, style: const TextStyle(color: quiet, fontSize: 12)),
      ),
      ...values.map(
        (v) => SimpleDialogOption(
          onPressed: () => Navigator.pop(c, v),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('${(v * 100).toStringAsFixed(0)} cm'),
          ),
        ),
      ),
    ],
  ),
);
Future<Bounds?> cropDialog(BuildContext context, Bounds bounds) {
  final ranges = [
    const RangeValues(0, 1),
    const RangeValues(0, 1),
    const RangeValues(0, 1),
  ];
  final mins = bounds.min.toJson(), sizes = bounds.size.toJson();
  return showDialog<Bounds>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: const Text('Crop to a spatial box'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Only points inside these metric ranges are kept. Faces crossing the box are removed.',
                style: TextStyle(fontSize: 12, color: quiet),
              ),
              const SizedBox(height: 16),
              for (var i = 0; i < 3; i++)
                Column(
                  children: [
                    Text(
                      '${['X', 'Y', 'Z'][i]}  ${(mins[i] + sizes[i] * ranges[i].start).toStringAsFixed(2)} – ${(mins[i] + sizes[i] * ranges[i].end).toStringAsFixed(2)} m',
                    ),
                    RangeSlider(
                      values: ranges[i],
                      onChanged: (v) => set(() => ranges[i] = v),
                    ),
                  ],
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final low = List.generate(
                    3,
                    (i) => mins[i] + sizes[i] * ranges[i].start,
                  ),
                  high = List.generate(
                    3,
                    (i) => mins[i] + sizes[i] * ranges[i].end,
                  );
              Navigator.pop(
                c,
                Bounds(
                  Vec3(low[0], low[1], low[2]),
                  Vec3(high[0], high[1], high[2]),
                ),
              );
            },
            child: const Text('Apply crop'),
          ),
        ],
      ),
    ),
  );
}
