# ORIGIN Scan

**Capture spaces. Preserve reality.**

A native mobile application for local environmental capture, inspection, editing, and interoperable 3D export. Flutter provides the shared interface; ARKit and ARCore supply real device data. No website or browser API is used for sensor access.

## Implementation status

This repository contains working application code, rather than a simulated scanner. Sensor capture still needs validation on physical devices before field deployment. **A passing import/export test or an emulator session is not evidence of LiDAR capture accuracy.** See [validation](docs/VALIDATION.md) for checks performed in this workspace and the remaining device acceptance procedure.

| Platform | Capture | Import / library / edit / export |
|---|---|---|
| iOS / iPadOS 16+ | Native ARKit mesh reconstruction, gated by `supportsSceneReconstruction(.mesh)` | Implemented |
| Android 8+ | Native ARCore raw depth, confidence, intrinsics and camera poses; gated by actual Depth support | Implemented |
| Other platforms | No device capture implementation | Shared core tests run on Windows; desktop apps are not shipped |

There are **no installed external hardware adapters**. Manufacturer integration requirements are shown as unavailable, and their files can be imported. E57, LAS, LAZ, arbitrary point-cloud surfacing, texture baking, loop-closure optimization, and automatic alignment across independent sessions are not implemented.

## Build and install

Use Flutter **3.47.8 stable / Dart 3.13.7** (or a compatible later release), Git, and the native platform SDK. Dependency versions are locked in `pubspec.lock`. Internet is needed to obtain build dependencies; the installed application's workflows run locally.

```sh
flutter pub get
flutter analyze
flutter test
```

### iPhone and iPad

Build on a Mac with a Flutter-compatible Xcode, iOS SDK, and command-line tools. This project uses Flutter's generated Swift Package Manager integration. The app target includes `OriginNative.swift`; no proprietary scanner library is required.

```sh
flutter build ios --simulator   # compilation / import and library UI checks
open ios/Runner.xcworkspace
```

In Xcode, select the Runner target, set your bundle identifier and signing team, choose the attached device, and run. Alternatively use `flutter run -d <device-id>`. Camera permission is requested when capture starts. Simulator capture is unavailable by design.

Capture requires a LiDAR-equipped device that reports ARKit scene reconstruction support, such as supported iPhone Pro / Pro Max and iPad Pro models. Capability detection is authoritative; a model name alone never enables scanning. Non-LiDAR devices retain the complete file workflow.

### Android

Install Android SDK 36, build tools, the NDK requested by Flutter, and JDK 21. Accept Android SDK licenses using your normal SDK setup.

```sh
flutter build apk --debug
flutter install -d <device-id>
# or
flutter run -d <device-id>
```

The APK is generated at `build/app/outputs/flutter-apk/app-debug.apk`. This is a development build. Configure your own Android release keystore before distributing a production build; the generated Flutter release configuration uses the development key until replaced.

An optimized, installable local build is also available at `build/app/outputs/flutter-apk/app-release.apk` (approximately 50.5 MB). It is development-signed. The release manifest has no INTERNET permission.

Google Play Services for AR and its device profile must be installed and up to date **before** going offline. ORIGIN does not install or update ARCore automatically. If ARCore is missing, depth capture stays disabled and importing remains available. On a candidate device, choose **Scan with Device** to grant camera permission and inspect actual depth support. ARCore's own initial provisioning may require internet; field scanning does not depend on a remote processing API. ARCore depth is camera-estimated depth, possibly fused with ToF hardware, and is never advertised as hardware LiDAR.

### This Windows workspace

Local tools used for verification are under ignored `.tools/`; they are not app dependencies or part of a release. The system's Unicode username triggers tool bugs in Flutter's analyzer and the emulator. An ASCII junction, `C:\Users\Public\origin-scan-work`, points to this workspace. Java's Windows selector also needed a workaround in this environment:

```powershell
Set-Location C:\Users\Public\origin-scan-work
$env:JAVA_TOOL_OPTIONS = '-Djava.nio.channels.spi.SelectorProvider=sun.nio.ch.WindowsSelectorProvider -Djdk.net.unixdomain.tmpdir=C:\Users\Public\origin-java-temp'
.\.tools\flutter\bin\flutter.bat test
.\.tools\flutter\bin\flutter.bat build apk --debug
```

Use a normal Flutter installation on other computers; this workaround is environment-specific.

## Capture a real space

1. Open **New Scan → Scan with Device** on a supported device.
2. Tap **Start Scan**, grant camera permission if needed, and wait for tracking.
3. Move slowly with overlapping passes. The camera feed and reconstructed geometry are native views. Tracking loss stops accumulation until tracking recovers.
4. Pause and resume within the same live session to capture additional segments in the same local coordinate frame. Return to a previously observed area after interruption.
5. Choose **Finish Scan**. The app assembles local journal chunks and opens review.
6. Rename, inspect, optionally clean, and choose **Save Scan**.

Mesh and point counts, observed mesh area on iOS, and buffer memory estimates reflect captured geometry. They are not a completeness score or a survey accuracy certificate. Android has no measured mesh area and shows point accumulation instead. iOS ARKit supplies a real triangle mesh; Android supplies a registered point cloud and does not invent a surface.

Capture caps at 2 million vertices/points, with a 256 MB free-space reserve. Raw depth retention is bounded to approximately 1 GB per session. Finish and export smaller independent segments for large sites. Each new session has its own origin. Do not merge independent sessions without control and registration in appropriate local software.

## Recovery and local storage

The root is `Documents/ORIGIN Scan` on iOS and the app's documents directory on Android. Its user-visible path appears in Settings and review. iOS exposes the documents directory in Files / Finder file sharing. Android exports use the Storage Access Framework; no broad storage permission is requested.

```text
ORIGIN Scan/
  settings.json
  projects/<id>/
    project.json             # versioned metadata / current revision pointer
    original.ply             # untouched canonical geometry, always retained
    imported-source.<ext>    # original selected input, when imported
    edit-<revision>.ply       # saved non-destructive edits
    preview.png              # derived from actual geometry
    raw/                     # optional mesh / depth journal and calibration metadata
  pending/<session-id>/
    session.json
    mesh-<anchor-id>.ply      # iOS: latest version per ARMeshAnchor
    part-<sequence>.ply       # Android: newly occupied metric voxels
    depth-<timestamp>.*       # optional real depth and confidence samples + camera pose
    capture.json             # native quality / source record, when finish succeeds
  exports/
    ORIGIN_Scan_<name>_<date>.<format>
    ORIGIN_Scan_<name>_<date>.<format>.json
```

Writes use staged files and durable replacement; metadata retains a fallback during replacement. Scan chunks are committed during capture, not only at finish. On relaunch, Home offers to recover pending geometry. Recovery opens the recorded geometry for review; it does not pretend a new sensor session can resume an old coordinate frame. Original data survives processing errors, and unreadable project folders are reported and left in place.

Deletion requires confirmation and removes only the selected project folder. Exports already saved elsewhere remain independent. App uninstall removes private data. Export field records to device storage before uninstalling. No account, sync, analytics, server, remote database, payments, or in-app upload exists. Android backup and device transfer are excluded; iOS documents are excluded from backup by the native plugin. A user can explicitly choose a destination in the OS picker; choose on-device storage when working offline.

## Import, inspection and editing

Open **Import Existing Scan** and choose PLY, OBJ, GLB, GLTF, STL, or XYZ. PLY / OBJ / STL / XYZ do not reliably declare units: the app asks for source units and converts once to metres. glTF 2.0 is interpreted in its specified metric coordinate system. No bounding-box normalization changes the model's scale.

The viewer is GPU rendered with SceneKit on Apple platforms and OpenGL ES 3 on Android. Orbit with one finger, pinch to zoom, and use two fingers to pan. Use Fit / View for perspective, top, front, and side views, Display for points / mesh / wireframe, and Fullscreen for inspection. Native renderers use a bounded interactive representation where needed; exports retain full geometry.

Measure selects two visible geometry points (surface hits on iOS meshes; nearest rendered vertices on point clouds and Android). It reports their Euclidean distance in the selected display unit. This is geometry-based snapping rather than a certified field measurement. Dimensions and distances can be displayed in metres or centimetres; file coordinates remain metres.

Available edits are spatial crop, radius-neighbor outlier removal, voxel downsampling with face remapping, conservative mesh smoothing with fixed boundaries, and an explicit small triangular-hole fill (edges ≤10 cm). Filling adds inferred faces and must be chosen explicitly. Larger and ambiguous holes remain open. Undo retains three recent edits, and Original reloads untouched geometry. Save commits the edited revision without replacing `original.ply`.

## Export and interoperability

Choose **Export**, select a format, and save through the OS picker. The app also keeps a validated copy under its local exports folder and displays the saved URI/path. The metadata sidecar can be exported separately.

| Format | Geometry | Details |
|---|---|---|
| PLY | Points / triangles | Binary little endian; xyz float32; optional RGB; metadata comment |
| OBJ | Triangles only | Coordinates and 1-based faces; metre comments; no texture/material baking |
| GLB | Points / triangles | glTF 2.0, embedded binary, metric transforms, mesh normals, metadata extras |
| GLTF | Points / triangles | Self-contained JSON with a base64 buffer; no network resources |
| STL | Triangles only | Binary; computed facet normals; metre declaration in header + sidecar |
| XYZ | Points | Text xyz in metres; comments + sidecar; triangle topology is omitted |

All exports include a JSON sidecar with name, source, capture/import date, units, coordinate system, dimensions, vertex/triangle counts, and available quality metadata. STL and XYZ consumers may ignore unit hints; explicitly set metres in those tools. PLY preserves imported per-vertex RGB. Other current exporters do not preserve color, texture, materials, or animations. Geometry is stored in right-handed Y-up local coordinates, with no invented global CRS / georeference. glTF node transforms are baked into imported coordinates; mirrored transforms reverse face winding.

The app reimports each generated export to check structure and extents before offering it. Import has a 256 MB input budget and a 5M-vertex / 10M-triangle geometry guard. glTF accepts uncompressed static points/triangles, node transforms, and embedded or sibling local buffers. Mobile file pickers typically copy one selected file: use GLB or embedded-buffer GLTF for portable mobile imports. Remote buffers, traversal outside the model folder, sparse/normalized accessors, Draco/meshopt requirements, skins and morph targets are rejected. Materials and external textures are not loaded.

## Hardware adapters and architecture

See [hardware integration](docs/HARDWARE.md) for SDK research, a capability matrix, and the adapter contract; see [architecture](docs/ARCHITECTURE.md) for data ownership and capture details.

```text
lib/core/              validated geometry, codecs, local processing, project persistence
lib/platform/          native capture bridge and ScannerAdapter contract
lib/ui/                shared home, scanning, library, review, settings
ios/Runner/OriginNative.swift
                      ARKit capture, durable anchor/depth journal, SceneKit viewer
android/app/src/main/kotlin/app/origin/origin_scan/
                      ARCore capture, local journal, GLES viewer and capability checks
test/                 deterministic geometry, recovery, export and offline UI tests
```
