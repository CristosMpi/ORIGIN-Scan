import ARKit
import AVFoundation
import Flutter
import SceneKit
import UIKit
import simd

private let originBackground = UIColor(red: 32/255, green: 38/255, blue: 36/255, alpha: 1)

final class OriginNative: NSObject, FlutterPlugin, FlutterStreamHandler {
    let capture = MeshCapture()
    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = OriginNative()
        let channel = FlutterMethodChannel(name: "app.origin/capture", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(plugin, channel: channel)
        FlutterEventChannel(name: "app.origin/capture-events", binaryMessenger: registrar.messenger()).setStreamHandler(plugin)
        registrar.register(CaptureFactory(plugin.capture), withId: "app.origin/capture-view")
        registrar.register(ViewerFactory(registrar.messenger()), withId: "app.origin/viewer")
        if var root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? root.setResourceValues(values)
        }
    }
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "capabilities":
            let supported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            result(["supported": supported, "source": "Apple LiDAR / ARKit mesh", "reason": supported ? "" : "This device has no ARKit scene-reconstruction support. Use a LiDAR-equipped iPhone Pro or iPad Pro, or import an existing scan."])
        case "start":
            guard let args = call.arguments as? [String: Any], let directory = args["directory"] as? String else { result(FlutterError(code: "arguments", message: "Missing capture directory.", details: nil)); return }
            AVCaptureDevice.requestAccess(for: .video) { allowed in
                DispatchQueue.main.async {
                    guard allowed else { result(FlutterError(code: "camera", message: "Camera access is required. Enable it in iOS Settings to scan.", details: nil)); return }
                    self.capture.start(directory: directory, retainRaw: args["retainRaw"] as? Bool ?? true, result: result)
                }
            }
        case "pause": capture.pause(result)
        case "resume": capture.resume(result)
        case "finish": capture.finish(result)
        default: result(FlutterMethodNotImplemented)
        }
    }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { capture.sink = events; return nil }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { capture.sink = nil; return nil }
}

private final class CaptureFactory: NSObject, FlutterPlatformViewFactory {
    let capture: MeshCapture
    init(_ capture: MeshCapture) { self.capture = capture }
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView { CapturePlatformView(capture.view, frame) }
}
private final class CapturePlatformView: NSObject, FlutterPlatformView {
    let content: ARSCNView
    init(_ view: ARSCNView, _ frame: CGRect) { content = view; super.init(); content.frame = frame }
    func view() -> UIView { content }
}

private struct MeshChunk {
    var vertices: [SIMD3<Float>]
    var indices: [UInt32]
    var area: Float
}

final class MeshCapture: NSObject, ARSessionDelegate {
    let view = ARSCNView(frame: .zero)
    let queue = DispatchQueue(label: "app.origin.mesh-journal", qos: .userInitiated)
    var sink: FlutterEventSink?
    private var directory: URL?
    private var capturing = false
    private var retainRaw = true
    private var chunks: [UUID: (Int, Int, Float)] = [:]
    private var updated: [UUID: TimeInterval] = [:]
    private var nodes: [UUID: SCNNode] = [:] // Main-thread renderer state.
    private var lastDepth = 0.0, lastStatus = 0.0
    private var previousPosition = SIMD3<Float>(repeating: 0), previousTime = 0.0
    private var depthBytes = 0, segments = 1, trackingLosses = 0
    private var guidance = "Move slowly", tracking = "initializing"
    private var configuration: ARWorldTrackingConfiguration?
    override init() {
        super.init()
        view.scene = SCNScene(); view.backgroundColor = originBackground
        view.session.delegate = self; view.session.delegateQueue = queue
        view.automaticallyUpdatesLighting = false
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self); view.session.pause() }
    func start(directory path: String, retainRaw: Bool, result: @escaping FlutterResult) {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else { result(FlutterError(code: "unsupported", message: "LiDAR scene reconstruction is unavailable.", details: nil)); return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        guard url.path.hasPrefix(docs + "/ORIGIN Scan/pending/") else { result(FlutterError(code: "storage", message: "Invalid local journal directory.", details: nil)); return }
        let config = ARWorldTrackingConfiguration(); config.sceneReconstruction = .mesh
        config.worldAlignment = .gravity
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { config.frameSemantics.insert(.sceneDepth) }
        nodes.values.forEach { $0.removeFromParentNode() }; nodes.removeAll()
        queue.async {
            self.directory = url; self.retainRaw = retainRaw; self.chunks.removeAll(); self.updated.removeAll()
            self.lastDepth = 0; self.lastStatus = 0; self.previousTime = 0; self.depthBytes = 0; self.segments = 1; self.trackingLosses = 0
            self.configuration = config; self.capturing = true; self.guidance = "Move slowly"; self.tracking = "initializing"
            DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = true; self.view.session.run(config, options: [.resetTracking, .removeExistingAnchors]); result(nil) }
        }
    }
    func pause(_ result: @escaping FlutterResult) {
        view.session.pause()
        let anchors = view.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        queue.async {
            if self.capturing { self.record(anchors, force: true) }
            self.capturing = false; self.guidance = "Capture paused"; self.emit()
            DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false; result(nil) }
        }
    }
    func resume(_ result: @escaping FlutterResult) {
        queue.async {
            guard let config = self.configuration else { DispatchQueue.main.async { result(FlutterError(code: "session", message: "Start a capture first.", details: nil)) }; return }
            self.capturing = true; self.segments += 1; self.guidance = "Relocalizing — return to the last scanned area"
            DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = true; self.view.session.run(config); result(nil) }
        }
    }
    func finish(_ result: @escaping FlutterResult) {
        view.session.pause()
        let anchors = view.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        queue.async {
            if self.capturing { self.record(anchors, force: true) }
            self.capturing = false; self.guidance = "Scan complete"; self.emit(); self.configuration = nil
            do { try self.writeQuality() } catch { self.fail(error.localizedDescription) }
            DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false; result(nil) }
        }
    }
    @objc private func memoryWarning() { queue.async { self.fail("Memory pressure — finish this segment and start a smaller scan") } }
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { record(anchors.compactMap { $0 as? ARMeshAnchor }) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { record(anchors.compactMap { $0 as? ARMeshAnchor }) }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        // Retain last-known chunks: ARKit may evict far-away anchors in large spaces.
        // Updated anchors replace by UUID, so updates never duplicate an existing chunk.
    }
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal: tracking = "tracking"; guidance = "Move slowly · revisit missing surfaces"
        case .notAvailable: tracking = "lost"; guidance = "Tracking lost — return to a familiar area"; trackingLosses += 1
        case .limited(let reason):
            tracking = "limited"
            switch reason {
            case .excessiveMotion: guidance = "Move slowly"
            case .insufficientFeatures: guidance = "Aim at a textured surface in better light"
            case .relocalizing: guidance = "Tracking lost — return to the last scanned area"
            default: guidance = "Move slowly to initialize tracking"
            }
            trackingLosses += 1
        }
        emit()
    }
    func sessionWasInterrupted(_ session: ARSession) { capturing = false; guidance = "Capture interrupted — resume in the last scanned area"; emit() }
    func session(_ session: ARSession, didFailWithError error: Error) { fail(error.localizedDescription) }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard capturing else { return }
        if ProcessInfo.processInfo.thermalState == .critical { fail("Device temperature is high — allow it to cool before continuing"); return }
        if retainRaw && tracking == "tracking" && frame.timestamp - lastDepth > 1, let depth = frame.sceneDepth {
            lastDepth = frame.timestamp
            do { try recordDepth(depth, frame: frame) } catch { fail("Depth journal failed: \(error.localizedDescription)") }
        }
        if frame.timestamp - lastStatus > 1 {
            lastStatus = frame.timestamp
            if tracking == "tracking" {
                let column = frame.camera.transform.columns.3, position = SIMD3<Float>(column.x, column.y, column.z)
                let dt = frame.timestamp - previousTime
                let speed = previousTime > 0 && dt > 0 ? simd_distance(position, previousPosition) / Float(dt) : 0
                previousPosition = position; previousTime = frame.timestamp
                guidance = speed > 0.6 ? "Move slowly" : "Scan the missing area · overlap your passes"
                if speed <= 0.6, let map = frame.sceneDepth?.depthMap {
                    CVPixelBufferLockBaseAddress(map, .readOnly)
                    if let base = CVPixelBufferGetBaseAddress(map) {
                        let x = CVPixelBufferGetWidth(map) / 2, y = CVPixelBufferGetHeight(map) / 2
                        let value = base.advanced(by: y * CVPixelBufferGetBytesPerRow(map) + x * 4).load(as: Float.self)
                        if value.isFinite && value > 4 { guidance = "Move closer for more detail" }
                    }
                    CVPixelBufferUnlockBaseAddress(map, .readOnly)
                }
            }
            emit()
        }
    }
    private func record(_ anchors: [ARMeshAnchor], force: Bool = false) {
        guard capturing, tracking == "tracking", let directory = directory else { return }
        for anchor in anchors {
            let time = ProcessInfo.processInfo.systemUptime
            if !force && time - (updated[anchor.identifier] ?? -100) < 1 { continue }
            let g = anchor.geometry, previous = chunks[anchor.identifier]?.0 ?? 0
            let total = chunks.values.reduce(0) { $0 + $1.0 }
            if total - previous + g.vertices.count > 2_000_000 { fail("Capture limit reached — finish this segment before continuing"); return }
            do {
                let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? Int64.max
                if capacity < 256 * 1024 * 1024 { fail("Storage is low — finish this capture and free local space"); return }
                let chunk = extract(anchor)
                let bytes = encodeChunk(chunk)
                try bytes.write(to: directory.appendingPathComponent("mesh-\(anchor.identifier.uuidString).ply"), options: .atomic)
                chunks[anchor.identifier] = (chunk.vertices.count, chunk.indices.count / 3, chunk.area); updated[anchor.identifier] = time
                let geometry = sceneGeometry(chunk, points: false)
                geometry.firstMaterial?.diffuse.contents = UIColor(red: .67, green: .85, blue: .67, alpha: .65)
                geometry.firstMaterial?.fillMode = .lines
                DispatchQueue.main.async {
                    let node = self.nodes[anchor.identifier] ?? SCNNode()
                    node.geometry = geometry
                    if node.parent == nil { self.view.scene.rootNode.addChildNode(node) }
                    self.nodes[anchor.identifier] = node
                }
            } catch { fail("Could not persist mesh: \(error.localizedDescription)"); return }
        }
    }
    private func extract(_ anchor: ARMeshAnchor) -> MeshChunk {
        let g = anchor.geometry, source = g.vertices, faces = g.faces
        var vertices = [SIMD3<Float>](); vertices.reserveCapacity(source.count)
        for i in 0..<source.count {
            let address = source.buffer.contents().advanced(by: source.offset + i * source.stride)
            let x = address.load(as: Float.self), y = address.advanced(by: 4).load(as: Float.self), z = address.advanced(by: 8).load(as: Float.self)
            let world = anchor.transform * SIMD4<Float>(x, y, z, 1)
            vertices.append(SIMD3(world.x, world.y, world.z))
        }
        var indices = [UInt32](); indices.reserveCapacity(faces.count * 3)
        for i in 0..<(faces.count * faces.indexCountPerPrimitive) {
            let pointer = faces.buffer.contents().advanced(by: i * faces.bytesPerIndex)
            indices.append(faces.bytesPerIndex == 2 ? UInt32(pointer.load(as: UInt16.self)) : pointer.load(as: UInt32.self))
        }
        var area: Float = 0
        for i in stride(from: 0, to: indices.count, by: 3) { area += simd_length(simd_cross(vertices[Int(indices[i+1])] - vertices[Int(indices[i])], vertices[Int(indices[i+2])] - vertices[Int(indices[i])])) / 2 }
        return MeshChunk(vertices: vertices, indices: indices, area: area)
    }
    private func recordDepth(_ depth: ARDepthData, frame: ARFrame) throws {
        guard let directory = directory, depthBytes < 1024 * 1024 * 1024 else { return }
        let map = depth.depthMap, width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        CVPixelBufferLockBaseAddress(map, .readOnly); defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(map) else { return }
        var bytes = Data(capacity: width * height * 4)
        for row in 0..<height { bytes.append(address.advanced(by: row * CVPixelBufferGetBytesPerRow(map)).assumingMemoryBound(to: UInt8.self), count: width * 4) }
        let name = "depth-\(Int(frame.timestamp * 1000))"
        try bytes.write(to: directory.appendingPathComponent(name + ".bin"), options: .atomic)
        var confidenceFile: Any = NSNull()
        if let confidence = depth.confidenceMap {
            CVPixelBufferLockBaseAddress(confidence, .readOnly); defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
            if let base = CVPixelBufferGetBaseAddress(confidence) {
                var c = Data(capacity: width * height)
                for row in 0..<height { c.append(base.advanced(by: row * CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self), count: width) }
                try c.write(to: directory.appendingPathComponent(name + "-confidence.bin"), options: .atomic); confidenceFile = name + "-confidence.bin"
            }
        }
        let matrix = frame.camera.transform, k = frame.camera.intrinsics
        let metadata: [String: Any] = ["encoding": "float32-little-endian-metres", "width": width, "height": height, "timestamp": frame.timestamp, "confidence": confidenceFile, "confidenceEncoding": "uint8: 0 low, 1 medium, 2 high", "cameraResolution": [frame.camera.imageResolution.width, frame.camera.imageResolution.height], "cameraIntrinsicsColumnMajor": (0..<3).flatMap { c in (0..<3).map { r in k[c][r] } }, "cameraToWorldColumnMajor": (0..<4).flatMap { c in (0..<4).map { r in matrix[c][r] } }]
        try JSONSerialization.data(withJSONObject: metadata).write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
        depthBytes += bytes.count + width * height
    }
    private func writeQuality() throws {
        guard let directory = directory else { return }
        let data: [String: Any] = ["source": "Apple LiDAR / ARKit mesh", "segments": segments, "trackingLossEvents": trackingLosses, "rawDepthBytes": depthBytes, "surfaceAreaM2": chunks.values.reduce(Float(0)) { $0 + $1.2 }, "accuracy": "Uncalibrated ARKit reconstruction; verify against field control", "coordinateSystem": "right-handed Y-up; metres; ARKit session origin"]
        try JSONSerialization.data(withJSONObject: data).write(to: directory.appendingPathComponent("capture.json"), options: .atomic)
    }
    private func emit() {
        let points = chunks.values.reduce(0) { $0 + $1.0 }, triangles = chunks.values.reduce(0) { $0 + $1.1 }, area = chunks.values.reduce(Float(0)) { $0 + $1.2 }
        let event: [String: Any] = ["points": points, "triangles": triangles, "surfaceArea": area, "memoryBytes": points * 12 + triangles * 12, "guidance": guidance, "tracking": tracking, "paused": !capturing]
        DispatchQueue.main.async { self.sink?(event) }
    }
    private func fail(_ message: String) { capturing = false; guidance = message; emit(); DispatchQueue.main.async { self.view.session.pause(); UIApplication.shared.isIdleTimerDisabled = false } }
}

private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
private func encodeChunk(_ chunk: MeshChunk) -> Data {
    var data = Data("ply\nformat binary_little_endian 1.0\ncomment units=metres; right-handed Y-up\nelement vertex \(chunk.vertices.count)\nproperty float x\nproperty float y\nproperty float z\nelement face \(chunk.indices.count / 3)\nproperty list uchar uint vertex_indices\nend_header\n".utf8)
    for p in chunk.vertices { appendLE(p.x.bitPattern, to: &data); appendLE(p.y.bitPattern, to: &data); appendLE(p.z.bitPattern, to: &data) }
    for i in stride(from: 0, to: chunk.indices.count, by: 3) { data.append(3); appendLE(chunk.indices[i], to: &data); appendLE(chunk.indices[i+1], to: &data); appendLE(chunk.indices[i+2], to: &data) }
    return data
}

private func sceneGeometry(_ chunk: MeshChunk, points: Bool) -> SCNGeometry {
    var vertices = Data(capacity: chunk.vertices.count * 12)
    for p in chunk.vertices { appendLE(p.x.bitPattern, to: &vertices); appendLE(p.y.bitPattern, to: &vertices); appendLE(p.z.bitPattern, to: &vertices) }
    let source = SCNGeometrySource(data: vertices, semantic: .vertex, vectorCount: chunk.vertices.count, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
    var indices = Data()
    let values = points ? stride(from: 0, to: chunk.vertices.count, by: max(1, chunk.vertices.count / 500_000)).map { UInt32($0) } : chunk.indices
    for v in values { appendLE(v, to: &indices) }
    let element = SCNGeometryElement(data: indices, primitiveType: points ? .point : .triangles, primitiveCount: points ? values.count : values.count / 3, bytesPerIndex: 4)
    element.pointSize = 3; element.minimumPointScreenSpaceRadius = 1; element.maximumPointScreenSpaceRadius = 4
    var sources = [source]
    if !points {
        var normals = [SIMD3<Float>](repeating: .zero, count: chunk.vertices.count)
        for i in stride(from: 0, to: chunk.indices.count, by: 3) {
            let a = Int(chunk.indices[i]), b = Int(chunk.indices[i+1]), c = Int(chunk.indices[i+2])
            let n = simd_cross(chunk.vertices[b] - chunk.vertices[a], chunk.vertices[c] - chunk.vertices[a]); normals[a] += n; normals[b] += n; normals[c] += n
        }
        var normalData = Data(capacity: normals.count * 12)
        for n in normals { let v = simd_length(n) > 0 ? simd_normalize(n) : SIMD3<Float>(0, 1, 0); appendLE(v.x.bitPattern, to: &normalData); appendLE(v.y.bitPattern, to: &normalData); appendLE(v.z.bitPattern, to: &normalData) }
        sources.append(SCNGeometrySource(data: normalData, semantic: .normal, vectorCount: normals.count, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12))
    }
    let geometry = SCNGeometry(sources: sources, elements: [element]), material = SCNMaterial()
    material.diffuse.contents = UIColor(red: .70, green: .80, blue: .68, alpha: 1); material.isDoubleSided = true
    material.lightingModel = points ? .constant : .blinn; geometry.materials = [material]
    return geometry
}

private func readCanonicalPly(_ path: String) throws -> MeshChunk {
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    guard let range = data.range(of: Data("end_header\n".utf8)), range.lowerBound < 65536, let header = String(data: data.prefix(range.upperBound), encoding: .utf8), header.contains("format binary_little_endian 1.0") else { throw NSError(domain: "origin", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid internal PLY file"]) }
    let lines = header.components(separatedBy: "\n")
    func count(_ key: String) -> Int { Int(lines.first { $0.hasPrefix("element \(key) ") }?.components(separatedBy: " ").last ?? "0") ?? 0 }
    let n = count("vertex"), faces = count("face"), stride = header.contains("property uchar red") ? 15 : 12, start = range.upperBound
    guard n > 0, n <= 5_000_000, faces <= 10_000_000, start + n * stride + faces * 13 == data.count else { throw NSError(domain: "origin", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid internal geometry size"]) }
    func u32(_ offset: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
    var vertices = [SIMD3<Float>](); vertices.reserveCapacity(n)
    for i in 0..<n { let o = start + i * stride; vertices.append(SIMD3(Float(bitPattern: u32(o)), Float(bitPattern: u32(o+4)), Float(bitPattern: u32(o+8)))) }
    var indices = [UInt32](); indices.reserveCapacity(faces * 3)
    for i in 0..<faces {
        let o = start + n * stride + i * 13
        guard data[o] == 3 else { throw NSError(domain: "origin", code: 3) }
        for j in 0..<3 { let value = u32(o + 1 + j * 4); guard value < UInt32(n) else { throw NSError(domain: "origin", code: 4) }; indices.append(value) }
    }
    return MeshChunk(vertices: vertices, indices: indices, area: 0)
}

private final class ViewerFactory: NSObject, FlutterPlatformViewFactory {
    let messenger: FlutterBinaryMessenger
    init(_ messenger: FlutterBinaryMessenger) { self.messenger = messenger }
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView { NativeViewer(frame, viewId, messenger) }
}

private final class NativeViewer: NSObject, FlutterPlatformView {
    let content = SCNView(frame: .zero), node = SCNNode(), camera = SCNNode(), markers = SCNNode()
    let channel: FlutterMethodChannel
    let worker = DispatchQueue(label: "app.origin.viewer", qos: .userInitiated)
    var chunk: MeshChunk?, meshGeometry: SCNGeometry?, pointGeometry: SCNGeometry?
    var measuring = false, first: SIMD3<Float>?, radius: Float = 1, center = SIMD3<Float>(repeating: 0)
    init(_ frame: CGRect, _ id: Int64, _ messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "app.origin/viewer/\(id)", binaryMessenger: messenger)
        super.init()
        content.frame = frame; content.backgroundColor = originBackground; content.scene = SCNScene(); content.autoenablesDefaultLighting = true
        camera.camera = SCNCamera(); content.scene!.rootNode.addChildNode(camera); content.pointOfView = camera
        content.scene!.rootNode.addChildNode(node); content.scene!.rootNode.addChildNode(markers); content.allowsCameraControl = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(selectPoint(_:))); content.addGestureRecognizer(tap)
        channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
    }
    func view() -> UIView { content }
    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "load":
            guard let path = args["path"] as? String else { result(FlutterError(code: "path", message: "Missing local file", details: nil)); return }
            worker.async {
                do {
                    let chunk = try readCanonicalPly(path), points = sceneGeometry(chunk, points: true), mesh = chunk.indices.isEmpty ? nil : sceneGeometry(chunk, points: false)
                    var low = chunk.vertices[0], high = low
                    for p in chunk.vertices { low = simd_min(low, p); high = simd_max(high, p) }
                    DispatchQueue.main.async {
                        self.chunk = chunk; self.meshGeometry = mesh; self.pointGeometry = points; self.center = (low + high) / 2; self.radius = max(simd_length(high - low) / 2, 0.01)
                        self.node.geometry = args["mode"] as? String == "points" ? points : mesh ?? points
                        self.setCamera("perspective"); result(nil)
                    }
                } catch { DispatchQueue.main.async { result(FlutterError(code: "geometry", message: error.localizedDescription, details: nil)) } }
            }
        case "view": setCamera(args["view"] as? String ?? "perspective"); result(nil)
        case "mode":
            let mode = args["mode"] as? String ?? "points"
            node.geometry = mode == "points" ? pointGeometry : meshGeometry ?? pointGeometry
            node.geometry?.firstMaterial?.fillMode = mode == "wireframe" ? .lines : .fill; result(nil)
        case "measure": measuring = args["enabled"] as? Bool ?? false; first = nil; markers.childNodes.forEach { $0.removeFromParentNode() }; result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }
    private func setCamera(_ view: String) {
        let direction: SIMD3<Float>
        switch view { case "top": direction = SIMD3(0, 1, 0.001); case "front": direction = SIMD3(0, 0, 1); case "side": direction = SIMD3(1, 0, 0); default: direction = simd_normalize(SIMD3(1, 0.65, 1)) }
        camera.simdPosition = center + direction * radius * 3.2
        camera.look(at: SCNVector3(center)); camera.camera?.zNear = Double(radius) / 10000; camera.camera?.zFar = Double(radius) * 100
        camera.camera?.usesOrthographicProjection = view != "perspective"; camera.camera?.orthographicScale = Double(radius) * 1.3
        content.defaultCameraController.target = SCNVector3(center)
    }
    @objc private func selectPoint(_ tap: UITapGestureRecognizer) {
        guard measuring, let chunk = chunk else { return }
        let location = tap.location(in: content)
        var selected: SIMD3<Float>?
        if !chunk.indices.isEmpty, let hit = content.hitTest(location, options: [.rootNode: node, .firstFoundOnly: true]).first { selected = SIMD3(hit.worldCoordinates.x, hit.worldCoordinates.y, hit.worldCoordinates.z) }
        if selected == nil {
            var closest: CGFloat = 24 * 24, depth: Float = 1
            for i in stride(from: 0, to: chunk.vertices.count, by: max(1, chunk.vertices.count / 500_000)) {
                let p = content.projectPoint(SCNVector3(chunk.vertices[i]))
                guard p.z > 0 && p.z < 1 else { continue }
                let dx = CGFloat(p.x) - location.x, dy = CGFloat(p.y) - location.y, distance = dx * dx + dy * dy
                if distance < closest || (abs(distance - closest) < 4 && p.z < depth) { closest = distance; depth = p.z; selected = chunk.vertices[i] }
            }
        }
        guard let p = selected else { return }
        if first == nil { markers.childNodes.forEach { $0.removeFromParentNode() } }
        let sphere = SCNSphere(radius: CGFloat(radius) * .008), marker = SCNNode(geometry: sphere)
        sphere.firstMaterial?.diffuse.contents = UIColor.orange; sphere.firstMaterial?.lightingModel = .constant; marker.simdPosition = p; markers.addChildNode(marker)
        if let start = first { channel.invokeMethod("measurement", arguments: ["distance": simd_distance(start, p), "from": [start.x, start.y, start.z], "to": [p.x, p.y, p.z]]); first = nil }
        else { first = p; channel.invokeMethod("measurement", arguments: ["from": [p.x, p.y, p.z]]) }
    }
}
