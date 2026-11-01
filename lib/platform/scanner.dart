import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class ScannerCapabilities {
  final bool supported, needsPermission;
  final String source, reason;
  ScannerCapabilities(
    this.supported,
    this.source,
    this.reason, {
    this.needsPermission = false,
  });
  factory ScannerCapabilities.fromMap(Map<Object?, Object?> m) =>
      ScannerCapabilities(
        m['supported'] == true,
        m['source'] as String? ?? 'Unavailable',
        m['reason'] as String? ?? '',
        needsPermission: m['needsPermission'] == true,
      );
}

class CaptureBridge {
  static const channel = MethodChannel('app.origin/capture');
  static const events = EventChannel('app.origin/capture-events');
  static Future<ScannerCapabilities> capabilities() async {
    if (!Platform.isIOS && !Platform.isAndroid) {
      return ScannerCapabilities(
        false,
        'Import only',
        'Device scanning requires an iOS LiDAR device or a compatible Android ARCore Depth device.',
      );
    }
    try {
      return ScannerCapabilities.fromMap(
        await channel.invokeMapMethod<Object?, Object?>('capabilities') ?? {},
      );
    } on PlatformException catch (e) {
      return ScannerCapabilities(
        false,
        'Unavailable',
        e.message ?? 'Unable to inspect depth hardware.',
      );
    }
  }

  static Future<void> start(String directory, String quality, bool raw) =>
      channel.invokeMethod('start', {
        'directory': directory,
        'quality': quality,
        'retainRaw': raw,
      });
  static Future<void> pause() => channel.invokeMethod('pause');
  static Future<void> resume() => channel.invokeMethod('resume');
  static Future<void> finish() => channel.invokeMethod('finish');
  static Future<ScannerCapabilities> requestCapabilities() async =>
      ScannerCapabilities.fromMap(
        await channel.invokeMapMethod<Object?, Object?>(
              'requestCapabilities',
            ) ??
            {},
      );
  static Stream<Map<String, dynamic>> get status => events
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from(e as Map));
}

class ScannerDevice {
  final String id, manufacturer, model, transport;
  const ScannerDevice(this.id, this.manufacturer, this.model, this.transport);
}

/// SDK adapters must return registered metric, right-handed Y-up frames.
/// Unregistered sensor sweeps must never be appended as if they share a pose.
abstract interface class ScannerAdapter {
  String get id;
  Future<List<ScannerDevice>> discover();
  Future<ScannerCapabilities> capabilities(ScannerDevice device);
  Future<void> connect(ScannerDevice device);
  Future<void> disconnect();
  Future<void> startCapture(Directory journalDirectory);
  Future<void> stopCapture();
  Stream<Map<String, dynamic>> get status;
  Stream<File> get registeredGeometryFrames;
}

/// Integration requirements only; deliberately not registered as usable devices.
const externalIntegrations = [
  (
    'Ouster OS sensors',
    'Local Ethernet / UDP',
    'Requires Ouster C++ SDK, sensor calibration metadata, pose registration, and physical device validation.',
  ),
  (
    'RealSense depth cameras',
    'USB-C / USB OTG',
    'Requires librealsense AAR/JNI, USB permissions, calibration, pose registration, and supported Android hardware.',
  ),
  (
    'Leica / FARO / Trimble',
    'Manufacturer SDK',
    'A licensed SDK and a tested device adapter are required. Import an exported PLY, OBJ, STL, XYZ, or glTF file instead.',
  ),
];
