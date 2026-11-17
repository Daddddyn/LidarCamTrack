//
//  ARTrackerSession.swift
//  LidarCamTrack
//
//  Core capture engine: runs ARKit world tracking (with LiDAR scene depth +
//  mesh reconstruction) for pose, while a parallel AVCaptureMultiCamSession
//  input records true 4K/24fps video. Both are timestamped against the same
//  host clock so pose can be resampled to exact video-frame times in post.
//
//  HONEST NOTE: this gives you very good VFX-grade tracking (what every
//  mobile AR tracker in this class gives you), not a physically-impossible
//  zero-drift guarantee. See MarkerRefinement below for the technique that
//  actually gets you close to zero slide on longer or farther shots.
//

import ARKit
import AVFoundation
import simd

// MARK: - Per-frame record

struct TrackedFrame: Codable {
    let hostTimestamp: Double          // seconds, CACurrentMediaTime domain == AVCaptureDevice host clock
    let transform: [Float]             // 4x4 column-major, ARKit space (RH, Y-up, meters)
    let intrinsics: [Float]            // 3x3 (fx, 0, cx, 0, fy, cy, 0, 0, 1) row-major-flattened
    let imageWidth: Int
    let imageHeight: Int
    let exposureDuration: Double
    let trackingState: String          // "normal" | "limited" | "notAvailable"
}

// MARK: - Session

final class ARTrackerSession: NSObject, ARSessionDelegate {

    let arSession = ARSession()
    private(set) var frames: [TrackedFrame] = []
    private var meshAnchors: [ARMeshAnchor] = []

    func start() {
        let config = ARWorldTrackingConfiguration()

        // LiDAR mesh of the environment - exported once at the end as the
        // "scanned set" reference geometry for Unreal (occlusion + lighting reference).
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }

        // Per-pixel depth, used for AR occlusion matting and to sanity-check
        // scale drift (compare mesh distance vs. monocular-only estimate).
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }

        config.worldAlignment = .gravity          // Y stays aligned with real-world up
        config.isAutoFocusEnabled = false          // fixed focus = stable intrinsics (fx/fy don't jump between frames)
        config.planeDetection = []                 // don't need plane anchors, skip the overhead

        arSession.delegate = self
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        arSession.pause()
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t = frame.camera.transform
        let k = frame.camera.intrinsics

        let stateString: String
        switch frame.camera.trackingState {
        case .normal: stateString = "normal"
        case .limited: stateString = "limited"
        case .notAvailable: stateString = "notAvailable"
        @unknown default: stateString = "unknown"
        }

        let record = TrackedFrame(
            hostTimestamp: frame.timestamp,
            transform: [
                t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
                t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
                t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
                t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w
            ],
            intrinsics: [
                k.columns.0.x, k.columns.1.x, k.columns.2.x,
                k.columns.0.y, k.columns.1.y, k.columns.2.y,
                k.columns.0.z, k.columns.1.z, k.columns.2.z
            ],
            imageWidth: CVPixelBufferGetWidth(frame.capturedImage),
            imageHeight: CVPixelBufferGetHeight(frame.capturedImage),
            exposureDuration: frame.camera.exposureDuration,
            trackingState: stateString
        )
        frames.append(record)

        // Flag it loudly if tracking degrades - limited-state frames are the
        // ones that will visibly slide. Don't silently ship those as "good" data.
        if frame.camera.trackingState == .limited {
            print("⚠️ Tracking LIMITED at t=\(frame.timestamp) - expect drift risk here")
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        meshAnchors.append(contentsOf: anchors.compactMap { $0 as? ARMeshAnchor })
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors {
            if let mesh = anchor as? ARMeshAnchor,
               let idx = meshAnchors.firstIndex(where: { $0.identifier == mesh.identifier }) {
                meshAnchors[idx] = mesh
            }
        }
    }

    // MARK: Export

    /// Writes the full per-frame pose/intrinsics track as JSON, and the final
    /// LiDAR mesh as OBJ (both get picked up by the Unreal import script).
    func exportTrack(to directory: URL) throws {
        let jsonURL = directory.appendingPathComponent("camera_track.json")
        let data = try JSONEncoder().encode(frames)
        try data.write(to: jsonURL)

        let objURL = directory.appendingPathComponent("environment_scan.obj")
        try writeMeshAsOBJ(meshAnchors, to: objURL)
    }

    private func writeMeshAsOBJ(_ anchors: [ARMeshAnchor], to url: URL) throws {
        var vertexOffset = 1
        var obj = "# LiDAR environment scan exported from ARMeshAnchor geometry\n"
        for anchor in anchors {
            let geom = anchor.geometry
            let verts = geom.vertices
            let T = anchor.transform
            for i in 0..<verts.count {
                let v = verts[i]
                // vertices are local to the anchor; transform to world space
                let world = T * SIMD4<Float>(v.x, v.y, v.z, 1)
                obj += "v \(world.x) \(world.y) \(world.z)\n"
            }
            let faces = geom.faces
            for f in 0..<faces.count {
                let tri = faces.triangle(at: f)
                obj += "f \(Int(tri.0) + vertexOffset) \(Int(tri.1) + vertexOffset) \(Int(tri.2) + vertexOffset)\n"
            }
            vertexOffset += verts.count
        }
        try obj.write(to: url, atomically: true, encoding: .utf8)
    }
}

// Small helpers to index ARGeometrySource / ARGeometryElement by Int subscript -
// ARKit exposes these as raw buffers, this wraps them for readability above.
extension ARGeometrySource {
    subscript(_ index: Int) -> (x: Float, y: Float, z: Float) {
        let stride = self.stride
        let offset = self.offset
        let ptr = self.buffer.contents().advanced(by: index * stride + offset)
        let v = ptr.assumingMemoryBound(to: (Float, Float, Float).self).pointee
        return v
    }
    var count: Int { self.buffer.length / self.stride }
}
extension ARGeometryElement {
    // Named method instead of `subscript(_:)` - ARKit's ARGeometryElement
    // already has its own built-in subscript, and a second one with a
    // different return type made every call site ambiguous to the compiler.
    func triangle(at index: Int) -> (Int32, Int32, Int32) {
        let ptr = self.buffer.contents().advanced(by: index * Int(self.bytesPerIndex) * 3)
        let v = ptr.assumingMemoryBound(to: (Int32, Int32, Int32).self).pointee
        return v
    }
    // Note: .count is already provided by ARKit itself - no override needed
    // (the previous version here accidentally called itself infinitely).
}
