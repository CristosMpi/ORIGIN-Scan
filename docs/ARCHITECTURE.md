# Local data and reconstruction

## Coordinate ownership

Canonical geometry contains typed float32 xyz vertices in metres and optional uint32 triangle indices and RGB. Geometry validates finite coordinates, face references, cardinality, and allocation limits. A right-handed Y-up session coordinate frame is retained. Model viewing moves a camera around geometry; it never rescales the saved vertices.

On Apple devices, each ARMeshAnchor vertex is multiplied by its 4×4 anchor-to-world transform. Triangle indices remain local to that chunk until project assembly offsets them. Updates replace the same anchor UUID's PLY atomically. Last-known chunks are retained if ARKit evicts a distant anchor. Tracking-limited updates are not persisted. ARKit itself controls mesh reconstruction/resolution and alignment; no cloud service is used.

On Android, actual raw depth uint16 samples (millimetres) are paired with confidence bytes. Pixels below 160/255 confidence, zero depth, and samples outside 0.2–8 m are skipped. Texture camera intrinsics are scaled to the depth map. Unprojection uses `(x-cx)z/fx, -(y-cy)z/fy, -z`; the ARCore camera-to-world pose then maps the sample to the session's right-handed frame. A metric voxel occupancy map retains one actual observation per cell. Timestamps avoid re-integrating the same raw estimate. No Poisson surface, camera-only photogrammetry, or synthetic replacement mesh is produced.

Moving-session drift is not corrected by an offline SLAM optimizer. Independent sessions are not automatically aligned. Data is appropriate for inspection and downstream locally controlled registration; accuracy requires physical validation.

## Threading and rendering

Flutter owns application state, controls, edits, preferences and manifests. File parsing and geometry processing use Dart isolates. Native capture channels carry only lifecycle controls, metrics, and directory paths.

ARKit delegate work runs on a serial journal queue. Rendering changes return to the main thread. SceneKit renders the live camera with captured mesh wireframes; review uses native orbit/pan/zoom, points, triangles and wireframe. Depth records preserve confidence, intrinsics, camera resolution and camera-to-world matrices in companion JSON.

Android uses a GLSurfaceView for the real OES camera stream and GPU point overlay. Depth integration and durable flushes run on the GL queue. Capture rendering samples at most about 300k points while all retained samples go to disk. Review uses GLES VBOs, depth testing, directional mesh shading, and a bounded triangle LOD. Canonical exports always use full retained geometry. Native measurement snaps to actual geometry, not screen-space pixels at arbitrary depth.

## Durable local projects

No database is necessary. `project.json` references an immutable current revision. Original canonical PLY is never edited. Edits stage a new file before the manifest pointer commits. A fallback manifest survives interrupted replacement. Three recent unsaved edit states can be undone in memory, and scratch files are kept inside the project folder. Errors leave original files available.

Native capture chunks are journaled periodically and on pause/finish. Home enumerates pending sessions containing real PLY chunks. Recovery validates and merges them, creates a draft, and retains raw samples if selected at capture time. A recovered project can be saved/exported; coordinate relocalization after process death is intentionally not claimed.

## Bounds and limitations

- Import: maximum 256 MB input data, 5M vertices and 10M triangles.
- Capture: maximum 2M retained vertices/points, with a local free-space reserve.
- Optional depth retention: approximately 1 GB per capture.
- These are safety guards rather than benchmarked device guarantees. Current parsers and reconstruction use bounded in-memory typed buffers; they are not an out-of-core GIS engine. Split very large sites into independent segments.
- No texture capture or texture baking, color fusion, georeferencing, E57/LAS/LAZ, advanced surface reconstruction, or loop-closure optimization is implemented.
- Simple polygon import uses fan triangulation; non-convex polygons should be triangulated in the source tool before importing.
- Optional smoothing and small-hole filling change measured geometry and are explicitly non-destructive.
- App preferences and manifests are local JSON. The application has no remote runtime API client or upload path.
