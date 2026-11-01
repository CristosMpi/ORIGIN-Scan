# Verification record

Shared-code tests exercise all six export/import formats, point-only mesh restrictions, ASCII and binary PLY, RGB retention, negative OBJ indices, explicit unit conversion, transformed glTF scenes, malformed and remote-buffer rejection, crop/downsampling/outlier/smoothing operations, local save/reopen/duplicate/delete, interrupted journal recovery, metadata fallbacks, and the offline home / import UI.

Synthetic metric geometry exists only inside tests and QA files. It is not shipped in the application and is never presented as a sensor capture.

## Verified in this workspace — 24 October 2026

- Flutter static analysis: no issues. All **16** Dart / Flutter tests passed, including an edit launched from a live review widget, executed in an isolate, saved, and reopened.
- Android debug and release-mode APKs compiled successfully with Flutter 3.47.8, JDK 21 and ARCore 1.57.0. Release-mode APK is approximately 50.5 MB and uses the development signing key; configure a private production keystore before distribution.
- Android API 36.1 emulator, **airplane mode enabled**: cold launch without an account; unavailable ARCore capture explained; actual OS file-picker PLY import with explicit metres; native GPU mesh rendering; perspective/front view and wireframe controls; local save; voxel edit; force-stop/relaunch and reopen of the saved project; export through Android Files.
- The GLB actually written through Android Files was pulled back from the emulator and passed the local Khronos glTF validator with **zero errors and zero warnings**. Locally generated GLB/GLTF fixtures also had zero errors/warnings. Independent trimesh loading of PLY/OBJ/STL confirmed the known one-metre dimensions and expected triangle counts.
- The merged release Android manifest contains **no INTERNET permission**. Backup is disabled and cloud/device-transfer exclusion rules are included.
- Release-mode installation preserved the saved project. Native fullscreen/front-view two-point measurement on known fixture vertices returned **1.414 m**, matching √2 m. The release app cold-launched in roughly 1.1 seconds on this emulator; this is an observation, not a physical-device performance guarantee.
- iOS source is present and connected to the Xcode target. **No Xcode/iOS build or real Apple capture was performed on this Windows host. No physical Android depth device or external scanner was available.**

Emulator tests found and led to fixes for unknown-format MIME filtering, a UI closure crossing an isolate boundary, and a GLES shader precision mismatch. The final build and regression tests include these fixes.

## Field acceptance still required

Use a physical LiDAR iPhone/iPad and a physically supported ARCore Depth device. Xcode compilation is required on a Mac. Windows and an Android emulator cannot establish that a LiDAR capture pipeline works on physical Apple hardware.

1. Preinstall platform dependencies; enable airplane mode and disable Wi-Fi.
2. Cold-launch with no account, inspect capability detection, and start capture.
3. Capture a textured measured object and room with at least two field control distances. Compare exported coordinates and viewer measurements against those controls.
4. Verify camera overlay and mesh/point changes correspond to the physical scene.
5. Cover the camera / move too rapidly; verify tracking-loss guidance and stopped accumulation. Recover tracking without duplicate or misaligned geometry.
6. Pause, move back to an observed area, resume and finish. Verify one shared origin.
7. Background the app; return and resume. Force-stop during capture, relaunch and recover journal geometry. Repeat under low storage / memory pressure.
8. Crop/clean/smooth; save, close, relaunch and reopen. Restore Original to verify non-destructive editing.
9. Export applicable formats through Files / SAF and open them in an independent local tool such as MeshLab, CloudCompare or Blender. Explicitly select metres where a format omits units. Inspect glTF with the Khronos validator.
10. Validate unsupported devices retain import/view/edit/export and never expose an active unavailable capture method. Direct external scanner capture remains unavailable until SDK/device integration testing is complete.

This application is not claimed to be survey-certified, ready for archaeological archival certification, or verified across all device models. Preserve original data, field controls and scanner provenance for downstream verification.
