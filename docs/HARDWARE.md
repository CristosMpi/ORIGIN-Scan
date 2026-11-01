# Scanner integration

Only device-native ARKit and ARCore capture engines are installed. External scanner cards describe integration requirements; they never simulate discovery or return placeholder devices. Importing a scanner's exported files is available now.

## Documented SDK paths

| Family | Official reference | Local transport | Remaining integration work |
|---|---|---|---|
| Ouster OS | [Ouster Sensor SDK](https://docs.ouster.com/), [source / BSD license](https://github.com/ouster-lidar/ouster-sdk) | Ethernet UDP plus local device configuration | Build mobile C++ bridge; query actual sensor calibration; decode SDK frames; implement motion registration; test a physical sensor |
| RealSense | [Official Android SDK instructions](https://github.com/realsenseai/librealsense/blob/master/doc/android.md) | USB host / OTG | Build/provide `librealsense.aar` and JNI; USB permissions; calibration and depth conversion; external camera pose tracking; test supported hardware |
| Leica, FARO, Trimble, other professional scanners | Manufacturer documentation / licensed SDK for the exact model | Model-dependent USB, local Wi-Fi or Ethernet | Obtain redistribution rights, SDK and hardware; implement discovery, calibration, poses, capture lifecycle and disconnect recovery |
| File exchange | PLY / OBJ / STL / XYZ / glTF 2.0 | OS local file picker | Implemented; E57/LAS/LAZ require an audited local codec before enabling |

The RealSense Android wrapper exists, but the vendor documentation distinguishes Android build guidance from validation on supported desktop platforms. This repository does not claim mobile RealSense compatibility. Raw ranging sweeps from a terrestrial sensor do not by themselves supply a registered moving 3D map. No undocumented manufacturer commands or universal Bluetooth/USB protocol have been invented.

## Adapter contract

Implement `ScannerAdapter` in `lib/platform/scanner.dart`. Its discovery result contains actual device identity and transport. Implement connect/disconnect, capability reporting, start/stop, status/errors, and registered geometry files. Capabilities must derive from the connected device / SDK, rather than the existence of a USB port or Bluetooth radio.

Each emitted file must be an atomically committed canonical PLY chunk in metres, right-handed Y-up, sharing one explicit session origin. A native SDK bridge should handle binary frames and write local files without transporting millions of boxed values over a Flutter channel. Keep sample timestamps, calibration, sensor-to-device extrinsics, sensor pose, confidence, and error events beside the journal. Do not append unregistered sweeps into a common model. Use a distinct project when a reliable shared transform is unavailable.

Register an adapter and expose its discover/connect UI only after it can be built with its SDK and validated with physical hardware. Local-network entitlements and permissions should be added only for the actual adapter transport; the current release has no generic network scanner permission or background discovery.

## Native capture references

- [Apple scene reconstruction and support checks](https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction)
- [Apple ARMeshAnchor](https://developer.apple.com/documentation/arkit/armeshanchor)
- [Google Raw Depth and confidence](https://developers.google.com/ar/develop/java/depth/raw-depth)
- [ARCore depth image format and timestamps](https://developers.google.com/ar/reference/java/com/google/ar/core/Frame)
- [AR Optional deployment / provisioning](https://developers.google.com/ar/develop/java/enable-arcore)

These references informed the implementation; no listed external device has been tested in this workspace.
