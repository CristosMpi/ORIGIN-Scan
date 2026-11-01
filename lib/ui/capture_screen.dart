import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/project_store.dart';
import '../platform/scanner.dart';
import 'app.dart';
import 'review_screen.dart';
import 'viewer.dart';

class CaptureScreen extends StatefulWidget {
  final ProjectStore store;
  final ScannerCapabilities capabilities;
  const CaptureScreen({
    super.key,
    required this.store,
    required this.capabilities,
  });
  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen>
    with WidgetsBindingObserver {
  StreamSubscription<Map<String, dynamic>>? subscription;
  Directory? directory;
  bool started = false, paused = false, working = false, finished = false;
  Map<String, dynamic> status = {};
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    subscription = CaptureBridge.status.listen(
      (m) {
        if (mounted) {
          setState(() {
            status = m;
            if (m['paused'] is bool) paused = m['paused'] as bool;
          });
        }
      },
      onError: (Object e) {
        if (mounted) setState(() => error = e.toString());
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive &&
        started &&
        !paused &&
        !finished) {
      CaptureBridge.pause();
      if (mounted) setState(() => paused = true);
    }
  }

  Future<void> start() async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      directory ??= await widget.store.beginCapture(widget.capabilities.source);
      await CaptureBridge.start(
        directory!.path,
        widget.store.settings.quality,
        widget.store.settings.retainRaw,
      );
      if (mounted) {
        setState(() {
          started = true;
          paused = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> pauseResume() async {
    try {
      if (paused) {
        await CaptureBridge.resume();
      } else {
        await CaptureBridge.pause();
      }
      if (mounted) setState(() => paused = !paused);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> finish() async {
    if ((status['points'] as num? ?? 0) == 0) {
      await showError(
        context,
        const FormatException(
          'No geometry has been captured yet. Keep visible surfaces in view until the point count increases, or leave the capture.',
        ),
      );
      return;
    }
    setState(() => working = true);
    try {
      await CaptureBridge.finish();
      finished = true;
      final p = await widget.store.recover(directory!),
          g = await widget.store.load(p);
      await writeThumbnail(g, widget.store.thumbnail(p));
      if (!mounted) return;
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute<void>(
          builder: (_) =>
              ReviewScreen(store: widget.store, project: p, geometry: g),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e\nRecorded chunks remain locally available for recovery.';
          working = false;
          paused = true;
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    subscription?.cancel();
    if (!finished && started) CaptureBridge.finish();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !started && !working,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop || working) return;
      final leave = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Leave this capture?'),
          content: const Text(
            'Recorded geometry stays on this device and can be recovered from Home.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Keep scanning'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Leave capture'),
            ),
          ],
        ),
      );
      if (leave == true && mounted) {
        await CaptureBridge.finish();
        finished = true;
        setState(() => started = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      }
    },
    child: Scaffold(
      backgroundColor: viewportColor,
      body: Stack(
        children: [
          Positioned.fill(
            child: Platform.isIOS
                ? const UiKitView(viewType: 'app.origin/capture-view')
                : const AndroidView(viewType: 'app.origin/capture-view'),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: working
                            ? null
                            : () => Navigator.maybePop(context),
                        icon: const Icon(Icons.close, color: Colors.white),
                        tooltip: 'Leave capture',
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'ORIGIN  /  CAPTURE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          letterSpacing: 2,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: started && !paused
                              ? const Color(0xffbcd5b6)
                              : Colors.grey,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!started)
                  Container(
                    margin: const EdgeInsets.all(20),
                    padding: const EdgeInsets.all(20),
                    color: const Color(0xe6222824),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.capabilities.source,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Move slowly around the space. Keep surfaces in view, with overlapping passes.\n\nA capture shares one local origin. Finish this segment before starting another.',
                          style: TextStyle(
                            color: Color(0xffc3ccc1),
                            height: 1.6,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                const Spacer(),
                if (error != null)
                  Container(
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.all(16),
                    color: const Color(0xff762f24),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Colors.white, height: 1.5),
                    ),
                  ),
                Container(
                  width: double.infinity,
                  color: const Color(0xee202624),
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Text(
                        working
                            ? 'Processing locally…'
                            : paused
                            ? status['guidance'] as String? ?? 'Capture paused'
                            : status['guidance'] as String? ??
                                  'Ready when you are.',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '${status['points'] ?? 0} points  ·  ${status['triangles'] ?? 0} triangles  ·  ${formatBytes((status['memoryBytes'] as num? ?? 0).toInt())} RAM',
                        style: const TextStyle(
                          color: Color(0xffc3ccc1),
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${status['surfaceArea'] == null ? 'Point-cloud accumulation' : 'Observed surface: ${(status['surfaceArea'] as num).toStringAsFixed(1)} m²'} · ${status['tracking'] ?? 'waiting'}',
                        style: const TextStyle(
                          color: Color(0xffc3ccc1),
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Observed area is not a completeness estimate.',
                        style: TextStyle(
                          color: Color(0xff9ba897),
                          fontSize: 10,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (!started)
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: working ? null : start,
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xffd5dfcb),
                              foregroundColor: ink,
                            ),
                            child: const Text('Start Scan'),
                          ),
                        )
                      else
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: working ? null : pauseResume,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                ),
                                icon: Icon(
                                  paused ? Icons.play_arrow : Icons.pause,
                                ),
                                label: Text(paused ? 'Resume' : 'Pause'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                onPressed: working ? null : finish,
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xffd5dfcb),
                                  foregroundColor: ink,
                                ),
                                child: const Text('Finish Scan'),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (working)
            const Center(
              child: CircularProgressIndicator(color: Color(0xffd5dfcb)),
            ),
        ],
      ),
    ),
  );
}
