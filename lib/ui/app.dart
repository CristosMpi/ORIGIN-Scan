import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../core/formats.dart';
import '../core/jobs.dart';
import '../core/project_store.dart';
import '../platform/scanner.dart';
import 'capture_screen.dart';
import 'review_screen.dart';
import 'viewer.dart';

const ink = Color(0xff252b26),
    paper = Color(0xfff5f4ee),
    accent = Color(0xffa9472c),
    lineColor = Color(0xffdcded5),
    quiet = Color(0xff687266);

class OriginApp extends StatelessWidget {
  final ProjectStore store;
  const OriginApp({super.key, required this.store});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ORIGIN Scan',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: paper,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        primary: ink,
        surface: paper,
        secondary: accent,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: paper,
        foregroundColor: ink,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 17,
          color: ink,
          fontWeight: FontWeight.w600,
        ),
      ),
      dividerTheme: const DividerThemeData(color: lineColor, thickness: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ink,
          foregroundColor: Colors.white,
          minimumSize: const Size(48, 54),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          minimumSize: const Size(48, 54),
          side: const BorderSide(color: lineColor),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    ),
    home: HomeScreen(store: store),
  );
}

class HomeScreen extends StatefulWidget {
  final ProjectStore store;
  const HomeScreen({super.key, required this.store});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<ScanProject> projects = [];
  List<Directory> recovery = [];
  ScannerCapabilities? capabilities;
  int selected = 0, usage = 0;
  String? busy;
  ProjectStore get store => widget.store;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final c = await CaptureBridge.capabilities();
      if (mounted) setState(() => capabilities = c);
      final p = await store.list(),
          r = await store.recoverable(),
          bytes = await store.storageBytes();
      if (mounted) {
        setState(() {
          projects = p;
          recovery = r;
          capabilities = c;
          usage = bytes;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<T?> work<T>(String label, Future<T> Function() action) async {
    setState(() => busy = label);
    try {
      return await action();
    } catch (e) {
      if (mounted) await showError(context, e);
      return null;
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  Future<void> open(ScanProject p) async {
    final g = await work('Opening local geometry…', () => store.load(p));
    if (g == null || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ReviewScreen(store: store, project: p, geometry: g),
      ),
    );
    await refresh();
  }

  Future<void> importScan() async {
    try {
      final file = await FilePicker.pickFile(
        // Android document providers often have no MIME mapping for PLY/XYZ.
        // Let the OS select any local file, then validate the actual extension/content.
        type: FileType.any,
        dialogTitle: 'Import PLY, OBJ, GLB, GLTF, STL, or XYZ',
      );
      if (file == null || file.path == null || !mounted) return;
      final ext = file.extension?.toLowerCase();
      double? scale = 1;
      if (ext != 'glb' && ext != 'gltf') scale = await importUnits(context);
      if (scale == null || !mounted) return;
      final factor = scale;
      final p = await work('Importing and validating geometry…', () async {
        final g = await loadGeometryJob(file.path!, unitScale: factor);
        final p = await store.create(
          g,
          name: path.basenameWithoutExtension(file.name),
          source: 'Imported ${ext?.toUpperCase() ?? 'file'}',
          originalPath: file.path,
          quality: {
            'importScaleToMetres': factor,
            'accuracy': 'Not supplied by source',
          },
        );
        await writeThumbnail(g, store.thumbnail(p));
        return p;
      });
      if (p != null) await open(p);
      await refresh();
    } catch (e) {
      if (mounted) await showError(context, e);
    }
  }

  Future<void> capture() async {
    if (capabilities?.needsPermission == true) {
      final checked = await work(
        'Checking device depth support…',
        CaptureBridge.requestCapabilities,
      );
      if (checked != null && mounted) setState(() => capabilities = checked);
    }
    if (capabilities?.supported != true || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            CaptureScreen(store: store, capabilities: capabilities!),
      ),
    );
    await refresh();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              const OriginMark(size: 24),
              const SizedBox(width: 10),
              Text(
                selected == 0
                    ? 'ORIGIN'
                    : ['Home', 'New scan', 'My Scans', 'Settings'][selected],
                style: TextStyle(letterSpacing: selected == 0 ? 3 : 0),
              ),
            ],
          ),
          actions: const [
            Center(
              child: Padding(
                padding: EdgeInsets.only(right: 20),
                child: Text(
                  'LOCAL / OFFLINE',
                  style: TextStyle(
                    fontSize: 9,
                    letterSpacing: 1.3,
                    color: quiet,
                  ),
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 940),
              child: IndexedStack(
                index: selected,
                children: [home(), scanOptions(), library(), settings()],
              ),
            ),
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: selected,
          backgroundColor: paper,
          indicatorColor: const Color(0xffe2e5db),
          onDestinationSelected: (i) => setState(() => selected = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.view_in_ar_outlined),
              label: 'Scan',
            ),
            NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              selectedIcon: Icon(Icons.folder),
              label: 'My Scans',
            ),
            NavigationDestination(icon: Icon(Icons.tune), label: 'Settings'),
          ],
        ),
      ),
      if (busy != null)
        Positioned.fill(
          child: ColoredBox(
            color: paper.withValues(alpha: .94),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(strokeWidth: 2),
                  const SizedBox(height: 20),
                  Text(busy!, style: const TextStyle(fontSize: 15)),
                ],
              ),
            ),
          ),
        ),
    ],
  );
  Widget home() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const SizedBox(height: 28),
      const Text(
        'FIELD CAPTURE, SIMPLIFIED',
        style: TextStyle(color: quiet, fontSize: 10, letterSpacing: 2),
      ),
      const SizedBox(height: 14),
      const Text(
        'ORIGIN Scan',
        style: TextStyle(
          color: ink,
          fontSize: 44,
          fontWeight: FontWeight.w500,
          letterSpacing: -2,
        ),
      ),
      const SizedBox(height: 12),
      const Text(
        'Capture spaces.\nPreserve reality.',
        style: TextStyle(
          fontSize: 25,
          color: quiet,
          height: 1.25,
          letterSpacing: -.5,
        ),
      ),
      const SizedBox(height: 30),
      Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: () => setState(() => selected = 1),
              icon: const Icon(Icons.add, size: 20),
              label: const Text('New Scan'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => setState(() => selected = 2),
              icon: const Icon(Icons.folder_outlined, size: 19),
              label: const Text('My Scans'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 20),
      const Row(
        children: [
          Icon(Icons.circle, size: 6, color: Color(0xff6e8467)),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Your spaces stay on your device.',
              style: TextStyle(color: quiet, fontSize: 12),
            ),
          ),
        ],
      ),
      const SizedBox(height: 36),
      const Divider(),
      const SizedBox(height: 14),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Recent scans',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17),
          ),
          Text(
            '${projects.length} LOCAL',
            style: const TextStyle(
              fontSize: 10,
              letterSpacing: 1,
              color: quiet,
            ),
          ),
        ],
      ),
      const SizedBox(height: 18),
      ...recovery.map(
        (dir) => Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: accent),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'An unfinished capture is safe on this device.',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                'Recover the recorded geometry for review. A new capture uses a new coordinate origin.',
                style: TextStyle(color: quiet, fontSize: 12),
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: () async {
                  final p = await work(
                    'Recovering captured geometry…',
                    () => store.recover(dir),
                  );
                  if (p != null) await open(p);
                  await refresh();
                },
                child: const Text('Recover scan'),
              ),
            ],
          ),
        ),
      ),
      if (projects.isEmpty)
        emptyState()
      else
        ...projects.take(3).map(projectRow),
      const SizedBox(height: 30),
      const Divider(),
      const SizedBox(height: 14),
      Text(
        capabilities?.supported == true
            ? capabilities!.source
            : 'Import, inspect, preserve',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 5),
      Text(
        capabilities?.supported == true
            ? 'Depth capture is available on this device.'
            : 'Open a local 3D file, or use a device with supported depth hardware.',
        style: const TextStyle(fontSize: 12, color: quiet, height: 1.5),
      ),
    ],
  );
  Widget emptyState() => Container(
    padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 20),
    decoration: BoxDecoration(
      border: Border.all(color: lineColor),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Column(
      children: [
        const OriginMark(size: 52, color: quiet),
        const SizedBox(height: 18),
        const Text('Ready for the field.', style: TextStyle(fontSize: 17)),
        const SizedBox(height: 8),
        const Text(
          'Your first capture begins here.\nScan a space or import an existing 3D file.',
          textAlign: TextAlign.center,
          style: TextStyle(color: quiet, fontSize: 13, height: 1.6),
        ),
        const SizedBox(height: 8),
        TextButton(onPressed: importScan, child: const Text('Import a scan →')),
      ],
    ),
  );
  Widget scanOptions() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const SizedBox(height: 24),
      const Text(
        'A space.\nA new perspective.',
        style: TextStyle(fontSize: 34, height: 1.15, letterSpacing: -1),
      ),
      const SizedBox(height: 16),
      const Text(
        'Choose how to bring your environment into ORIGIN.',
        style: TextStyle(color: quiet, height: 1.6),
      ),
      const SizedBox(height: 28),
      methodCard(
        '01',
        Icons.sensors,
        'Scan with Device',
        capabilities?.supported == true
            ? '${capabilities!.source}\nCapture registered spatial geometry in real time.'
            : capabilities?.reason ?? 'Checking depth capabilities…',
        capture,
        enabled:
            capabilities?.supported == true ||
            capabilities?.needsPermission == true,
      ),
      methodCard(
        '02',
        Icons.usb,
        'Connect External Scanner',
        'Review hardware integration requirements and supported import formats.',
        () => showExternal(context, importScan),
      ),
      methodCard(
        '03',
        Icons.file_open_outlined,
        'Import Existing Scan',
        'PLY · OBJ · GLB · GLTF · STL · XYZ\nOpen a file from local storage.',
        importScan,
      ),
      const SizedBox(height: 18),
      const Text(
        'Metres. Local coordinates. Original data preserved.\nNo account or connection required.',
        style: TextStyle(color: quiet, fontSize: 12, height: 1.8),
      ),
    ],
  );
  Widget methodCard(
    String number,
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap, {
    bool enabled = true,
  }) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    decoration: BoxDecoration(
      color: enabled ? const Color(0xfffbfbf6) : const Color(0xffeeeee6),
      border: Border.all(color: lineColor),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: ListTile(
        enabled: enabled,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 14,
        ),
        minLeadingWidth: 26,
        leading: Text(
          number,
          style: const TextStyle(fontSize: 11, color: quiet),
        ),
        title: Row(
          children: [
            Icon(icon, size: 22, color: enabled ? ink : quiet),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: enabled ? ink : quiet,
                ),
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            subtitle,
            style: const TextStyle(color: quiet, fontSize: 12, height: 1.6),
          ),
        ),
        trailing: enabled
            ? const Icon(Icons.arrow_forward, size: 20)
            : const Icon(Icons.block, color: quiet, size: 20),
        onTap: enabled ? onTap : null,
      ),
    ),
  );
  Widget library() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Row(
        children: [
          const Expanded(
            child: Text(
              'My Scans',
              style: TextStyle(fontSize: 32, letterSpacing: -1),
            ),
          ),
          IconButton(
            tooltip: 'Import scan',
            onPressed: importScan,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        '${projects.length} projects · ${formatBytes(usage)} on this device',
        style: const TextStyle(color: quiet, fontSize: 13),
      ),
      const SizedBox(height: 24),
      if (projects.isEmpty) emptyState() else ...projects.map(projectRow),
      ...store.warnings.map(
        (w) => Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(w, style: const TextStyle(color: accent, fontSize: 12)),
        ),
      ),
    ],
  );
  Widget projectRow(ScanProject p) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    decoration: BoxDecoration(
      border: Border.all(color: lineColor),
      borderRadius: BorderRadius.circular(6),
    ),
    child: InkWell(
      onTap: () => open(p),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: store.thumbnail(p).existsSync()
                  ? Image.file(
                      store.thumbnail(p),
                      width: 78,
                      height: 72,
                      fit: BoxFit.cover,
                      cacheWidth: 240,
                      errorBuilder: (_, _, _) => const SizedBox(
                        width: 78,
                        height: 72,
                        child: Icon(Icons.view_in_ar),
                      ),
                    )
                  : const SizedBox(
                      width: 78,
                      height: 72,
                      child: Icon(Icons.view_in_ar, color: quiet),
                    ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${shortDate(p.created)} · ${p.saved ? 'PLY' : 'DRAFT'} · ${formatBytes(p.bytes)}',
                    style: const TextStyle(fontSize: 11, color: quiet),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    p.source,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: quiet),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Project actions',
              onSelected: (s) async {
                if (s == 'open') await open(p);
                if (s == 'rename' && mounted) {
                  final name = await nameDialog(context, p.name);
                  if (name != null) {
                    await work('Renaming…', () => store.rename(p, name));
                  }
                }
                if (s == 'duplicate') {
                  await work(
                    'Duplicating local project…',
                    () => store.duplicate(p),
                  );
                }
                if (s == 'delete' &&
                    mounted &&
                    await confirmDelete(context, p.name)) {
                  await work('Deleting local files…', () => store.delete(p));
                }
                await refresh();
              },
              itemBuilder: (_) => ['open', 'rename', 'duplicate', 'delete']
                  .map(
                    (s) => PopupMenuItem(
                      value: s,
                      child: Text(s[0].toUpperCase() + s.substring(1)),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    ),
  );
  Widget settings() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Text(
        'Less setup.\nMore discovery.',
        style: TextStyle(fontSize: 32, letterSpacing: -1, height: 1.15),
      ),
      const SizedBox(height: 28),
      DropdownButtonFormField<ScanFormat>(
        initialValue: store.settings.exportFormat,
        decoration: const InputDecoration(labelText: 'Default export format'),
        items: ScanFormat.values
            .map((f) => DropdownMenuItem(value: f, child: Text(f.label)))
            .toList(),
        onChanged: (f) {
          if (f != null) {
            setState(() => store.settings.exportFormat = f);
            work('Saving preferences…', store.saveSettings);
          }
        },
      ),
      const SizedBox(height: 20),
      DropdownButtonFormField<String>(
        initialValue: store.settings.quality,
        decoration: const InputDecoration(labelText: 'Capture sampling'),
        items: const [
          DropdownMenuItem(
            value: 'balanced',
            child: Text('Balanced · 2 cm voxels'),
          ),
          DropdownMenuItem(
            value: 'detail',
            child: Text('Detail · 1 cm voxels'),
          ),
          DropdownMenuItem(
            value: 'large',
            child: Text('Large space · 5 cm voxels'),
          ),
        ],
        onChanged: (f) {
          if (f != null) {
            setState(() => store.settings.quality = f);
            work('Saving preferences…', store.saveSettings);
          }
        },
      ),
      const SizedBox(height: 12),
      const Text(
        'ARKit chooses its own native mesh resolution. Sampling affects Android accumulation. Capture has a 2M vertex safety limit.',
        style: TextStyle(fontSize: 11, color: quiet, height: 1.6),
      ),
      const SizedBox(height: 20),
      DropdownButtonFormField<String>(
        initialValue: store.settings.units,
        decoration: const InputDecoration(labelText: 'Display units'),
        items: const [
          DropdownMenuItem(value: 'm', child: Text('Metres')),
          DropdownMenuItem(value: 'cm', child: Text('Centimetres')),
        ],
        onChanged: (f) {
          if (f != null) {
            setState(() => store.settings.units = f);
            work('Saving preferences…', store.saveSettings);
          }
        },
      ),
      const SizedBox(height: 16),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Keep raw capture data',
          style: TextStyle(fontSize: 15),
        ),
        subtitle: const Text(
          'Retain depth samples and mesh journal chunks. Original imported geometry is always kept.',
          style: TextStyle(fontSize: 12, color: quiet),
        ),
        value: store.settings.retainRaw,
        onChanged: (v) {
          setState(() => store.settings.retainRaw = v);
          work('Saving preferences…', store.saveSettings);
        },
      ),
      const Divider(height: 36),
      const Text(
        'LOCAL STORAGE',
        style: TextStyle(fontSize: 10, letterSpacing: 1.5, color: quiet),
      ),
      const SizedBox(height: 12),
      Text(formatBytes(usage), style: const TextStyle(fontSize: 24)),
      const SizedBox(height: 8),
      SelectableText(
        store.root.path,
        style: const TextStyle(fontSize: 12, color: quiet, height: 1.5),
      ),
      const SizedBox(height: 8),
      const Text(
        'Export through the system file picker. App removal deletes private files; export field records before uninstalling.',
        style: TextStyle(fontSize: 12, color: quiet, height: 1.6),
      ),
      const Divider(height: 36),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Scanner connections'),
        subtitle: const Text(
          'Integration requirements · file import available',
        ),
        trailing: const Icon(Icons.arrow_forward, size: 18),
        onTap: () => showExternal(context, importScan),
      ),
      const Divider(height: 36),
      const Text(
        'ORIGIN Scan  /  1.0.0',
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 10),
      const Text(
        'Built for places that matter.\nAll geometry processing and storage take place on this device. No accounts, analytics, or remote services.\n\nDepth geometry is an estimate. Validate scale and accuracy against field control before relying on a measurement.',
        style: TextStyle(color: quiet, fontSize: 12, height: 1.8),
      ),
    ],
  );
}

class OriginMark extends StatelessWidget {
  final double size;
  final Color color;
  const OriginMark({super.key, this.size = 24, this.color = ink});
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _OriginMarkPainter(color));
}

class _OriginMarkPainter extends CustomPainter {
  final Color color;
  _OriginMarkPainter(this.color);
  @override
  void paint(Canvas c, Size s) {
    final p = Paint()
      ..color = color
      ..strokeWidth = s.width / 20
      ..style = PaintingStyle.stroke;
    c.drawRect(
      Rect.fromLTWH(
        s.width * .12,
        s.height * .12,
        s.width * .76,
        s.height * .76,
      ),
      p,
    );
    c.drawLine(
      Offset(s.width * .12, s.height * .68),
      Offset(s.width * .68, s.height * .12),
      p,
    );
    c.drawLine(
      Offset(s.width * .32, s.height * .88),
      Offset(s.width * .88, s.height * .32),
      p,
    );
  }

  @override
  bool shouldRepaint(_OriginMarkPainter old) => old.color != color;
}

String formatBytes(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1048576
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : bytes < 1073741824
    ? '${(bytes / 1048576).toStringAsFixed(1)} MB'
    : '${(bytes / 1073741824).toStringAsFixed(2)} GB';
String shortDate(DateTime d) =>
    '${d.toLocal().day.toString().padLeft(2, '0')}.${d.toLocal().month.toString().padLeft(2, '0')}.${d.toLocal().year}';
Future<void> showError(BuildContext c, Object e) => showDialog<void>(
  context: c,
  builder: (c) => AlertDialog(
    title: const Text('Unable to complete'),
    content: SingleChildScrollView(
      child: Text(e.toString().replaceFirst('FormatException: ', '')),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
    ],
  ),
);
Future<bool> confirmDelete(BuildContext c, String name) async =>
    await showDialog<bool>(
      context: c,
      builder: (c) => AlertDialog(
        title: Text('Delete “$name”?'),
        content: const Text(
          'This permanently removes this project and its associated local data from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep scan'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete', style: TextStyle(color: accent)),
          ),
        ],
      ),
    ) ??
    false;
Future<String?> nameDialog(BuildContext context, String initial) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Scan name'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 100,
        onSubmitted: (v) => Navigator.pop(c, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
  return result;
}

Future<double?> importUnits(BuildContext context) => showDialog<double>(
  context: context,
  builder: (c) => SimpleDialog(
    title: const Text('What units does this file use?'),
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Text(
          'This format does not reliably declare scale. Choose the source units. ORIGIN stores geometry in metres.',
          style: TextStyle(color: quiet, height: 1.5),
        ),
      ),
      for (final option in [
        ('Metres', 1.0),
        ('Centimetres', .01),
        ('Millimetres', .001),
        ('Feet', .3048),
      ])
        SimpleDialogOption(
          onPressed: () => Navigator.pop(c, option.$2),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(option.$1),
          ),
        ),
    ],
  ),
);
Future<void> showExternal(BuildContext context, VoidCallback import) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('External scanners', style: TextStyle(fontSize: 25)),
                const SizedBox(height: 12),
                const Text(
                  'No direct hardware adapters are installed. These integrations require an SDK and device testing before capture can be enabled.',
                  style: TextStyle(color: quiet, height: 1.6),
                ),
                const SizedBox(height: 20),
                ...externalIntegrations.map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${e.$1} · ${e.$2}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          e.$3,
                          style: const TextStyle(
                            fontSize: 12,
                            color: quiet,
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'UNAVAILABLE · SDK REQUIRED',
                          style: TextStyle(
                            fontSize: 9,
                            color: accent,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(c);
                    import();
                  },
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('Import a scanner export'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
