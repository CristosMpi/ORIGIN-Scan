import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/geometry.dart';

const viewportColor = Color(0xff202624);

class GeometryViewer extends StatefulWidget {
  final String path;
  final Geometry geometry;
  final ValueChanged<String>? onMeasurement;
  final bool fullscreen;
  final String units;
  const GeometryViewer({
    super.key,
    required this.path,
    required this.geometry,
    this.onMeasurement,
    this.fullscreen = false,
    this.units = 'm',
  });
  @override
  State<GeometryViewer> createState() => _GeometryViewerState();
}

class _GeometryViewerState extends State<GeometryViewer> {
  MethodChannel? channel;
  String mode = 'mesh', view = 'perspective', error = '';
  bool measuring = false;
  String measurementLabel = '';
  void showMeasurement(String label) {
    setState(() => measurementLabel = label);
    widget.onMeasurement?.call(label);
  }

  @override
  void initState() {
    super.initState();
    mode = widget.geometry.hasMesh ? 'mesh' : 'points';
  }

  void created(int id) {
    channel = MethodChannel('app.origin/viewer/$id');
    channel!.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'measurement') {
        final m = Map<String, dynamic>.from(call.arguments as Map);
        final factor = widget.units == 'cm' ? 100 : 1;
        showMeasurement(
          m['distance'] == null
              ? 'First point selected. Tap the second point.'
              : '${((m['distance'] as num) * factor).toStringAsFixed(widget.units == 'cm' ? 1 : 3)} ${widget.units}',
        );
      } else if (call.method == 'error') {
        setState(() => error = call.arguments.toString());
      }
    });
    command('load', {'path': widget.path, 'mode': mode});
  }

  Future<void> command(String method, [Map<String, dynamic>? args]) async {
    try {
      await channel?.invokeMethod(method, args);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  void dispose() {
    channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const gestures = <Factory<OneSequenceGestureRecognizer>>{};
    return ColoredBox(
      color: viewportColor,
      child: Stack(
        children: [
          Positioned.fill(
            child: Platform.isIOS
                ? UiKitView(
                    viewType: 'app.origin/viewer',
                    onPlatformViewCreated: created,
                    gestureRecognizers: gestures,
                  )
                : Platform.isAndroid
                ? AndroidView(
                    viewType: 'app.origin/viewer',
                    onPlatformViewCreated: created,
                    gestureRecognizers: gestures,
                  )
                : CustomPaint(
                    painter: PointPreview(widget.geometry, dark: true),
                  ),
          ),
          Positioned(
            top: 16,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              color: const Color(0xcc202624),
              child: Text(
                '${widget.geometry.hasMesh ? 'TRIANGLE MESH' : 'POINT CLOUD'}  ·  METRIC',
                style: const TextStyle(
                  color: Color(0xffcfdbcf),
                  fontSize: 10,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),
          if (measurementLabel.isNotEmpty && widget.onMeasurement == null)
            Positioned(
              top: 56,
              left: 16,
              right: 16,
              child: Container(
                color: const Color(0xdd202624),
                padding: const EdgeInsets.all(12),
                child: Text(
                  measurementLabel,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
            ),
          if (error.isNotEmpty)
            Center(
              child: Container(
                color: Colors.black87,
                padding: const EdgeInsets.all(16),
                child: Text(error, style: const TextStyle(color: Colors.white)),
              ),
            ),
          Positioned(
            left: 12,
            bottom: 12,
            right: 12,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _tool(
                  Icons.center_focus_strong,
                  'Fit',
                  () => command('view', {'view': 'perspective'}),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Camera view',
                  initialValue: view,
                  onSelected: (s) {
                    setState(() => view = s);
                    command('view', {'view': s});
                  },
                  itemBuilder: (_) => ['perspective', 'top', 'front', 'side']
                      .map(
                        (s) => PopupMenuItem(
                          value: s,
                          child: Text(s[0].toUpperCase() + s.substring(1)),
                        ),
                      )
                      .toList(),
                  child: const _ToolFace(Icons.view_in_ar_outlined, 'View'),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Render mode',
                  initialValue: mode,
                  onSelected: (s) {
                    setState(() => mode = s);
                    command('mode', {'mode': s});
                  },
                  itemBuilder: (_) =>
                      [
                            'points',
                            if (widget.geometry.hasMesh) ...[
                              'mesh',
                              'wireframe',
                            ],
                          ]
                          .map(
                            (s) => PopupMenuItem(
                              value: s,
                              child: Text(s[0].toUpperCase() + s.substring(1)),
                            ),
                          )
                          .toList(),
                  child: const _ToolFace(Icons.layers_outlined, 'Display'),
                ),
                _tool(
                  Icons.straighten,
                  measuring ? 'Measuring' : 'Measure',
                  () {
                    setState(() => measuring = !measuring);
                    command('measure', {'enabled': measuring});
                    showMeasurement(
                      measuring ? 'Tap two visible surface points.' : '',
                    );
                  },
                  active: measuring,
                ),
                if (!widget.fullscreen)
                  _tool(
                    Icons.fullscreen,
                    'Fullscreen',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          backgroundColor: viewportColor,
                          appBar: AppBar(
                            backgroundColor: viewportColor,
                            foregroundColor: Colors.white,
                            title: const Text('Inspect geometry'),
                          ),
                          body: GeometryViewer(
                            path: widget.path,
                            geometry: widget.geometry,
                            fullscreen: true,
                            units: widget.units,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tool(
    IconData icon,
    String text,
    VoidCallback onTap, {
    bool active = false,
  }) => Semantics(
    button: true,
    label: text,
    child: InkWell(
      onTap: onTap,
      child: _ToolFace(icon, text, active: active),
    ),
  );
}

class _ToolFace extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  const _ToolFace(this.icon, this.label, {this.active = false});
  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 48),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: active ? const Color(0xffa3482c) : const Color(0xe6333b37),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: Colors.white),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
      ],
    ),
  );
}

/// Thumbnail made exclusively from this project's real geometry.
class PointPreview extends CustomPainter {
  final Geometry geometry;
  final bool dark;
  PointPreview(this.geometry, {this.dark = false});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(
      dark ? viewportColor : const Color(0xffe8e9e1),
      BlendMode.src,
    );
    final center = geometry.bounds.center,
        scale =
            math.min(size.width, size.height) *
            .7 /
            math.max(geometry.bounds.size.length, .001);
    final step = math.max(1, geometry.vertexCount ~/ 6000);
    final paint = Paint()
      ..color = dark ? const Color(0xffbbd5bc) : const Color(0xff526756);
    final dots = <Offset>[];
    for (var i = 0; i < geometry.vertexCount; i += step) {
      final p = geometry.point(i) - center;
      dots.add(
        Offset(
          size.width / 2 + (p.x * .82 - p.z * .58) * scale,
          size.height / 2 - (p.y * .9 - p.z * .3 - p.x * .2) * scale,
        ),
      );
    }
    paint.strokeWidth = 1.4;
    canvas.drawPoints(ui.PointMode.points, dots, paint);
  }

  @override
  bool shouldRepaint(PointPreview oldDelegate) =>
      oldDelegate.geometry != geometry || oldDelegate.dark != dark;
}

Future<void> writeThumbnail(Geometry g, File file) async {
  final recorder = ui.PictureRecorder();
  PointPreview(g).paint(Canvas(recorder), const Size(480, 320));
  final picture = recorder.endRecording(),
      image = await picture.toImage(480, 320);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  if (bytes != null) {
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
  }
  image.dispose();
  picture.dispose();
}
