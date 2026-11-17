//
//  MultiCamCaptureSession.swift
//  LidarCamTrack
//
//  Runs a true 4K/24fps H.264/ProRes recording on a dedicated AVCaptureSession
//  while ARTrackerSession.swift runs ARKit for pose, at the same time, on the
//  same physical lens. Both are driven off the shared host clock so you can
//  line up any video frame to its nearest pose sample afterward without
//  guessing.
//
//  WHY TWO SESSIONS: ARKit's own capturedImage buffer is capped well below
//  4K. AVCaptureMultiCamSession lets a second, independent AVCaptureDeviceInput
//  pull full-quality 4K24 off the same device concurrently with ARKit holding
//  its own (lower-res) feed for tracking. This is the standard way around the
//  "ARKit owns the camera" limitation.
//

import AVFoundation
import ARKit
import simd

final class MultiCamCaptureSession: NSObject {

    private let multiCamSession = AVCaptureMultiCamSession()
    private var videoInput: AVCaptureDeviceInput?
    private var movieOutput = AVCaptureMovieFileOutput()
    private(set) var isRecording = false

    /// Call once ARTrackerSession.start() has already been called, so ARKit
    /// has first claim on the device and this session attaches alongside it.
    func configure(using device: AVCaptureDevice) throws {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw CaptureError.multiCamUnsupported
        }

        multiCamSession.beginConfiguration()
        defer { multiCamSession.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: device)
        guard multiCamSession.canAddInput(input) else {
            throw CaptureError.cannotAddInput
        }
        multiCamSession.addInputWithNoConnections(input)
        self.videoInput = input

        // Lock to exactly 4K / 24fps - don't let the system auto-pick a
        // "close enough" format, since intrinsics/FOV math downstream assumes
        // this exact resolution.
        guard let format = device.formats.first(where: { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let hasExact24 = fmt.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 24.0 && $0.maxFrameRate >= 24.0
            }
            return dims.width == 3840 && dims.height == 2160 && hasExact24
        }) else {
            throw CaptureError.formatUnavailable
        }

        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 24)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 24)
        device.unlockForConfiguration()

        guard multiCamSession.canAddOutput(movieOutput) else {
            throw CaptureError.cannotAddOutput
        }
        multiCamSession.addOutputWithNoConnections(movieOutput)

        guard let videoPort = input.ports(for: .video,
                                           sourceDeviceType: device.deviceType,
                                           sourceDevicePosition: device.position).first else {
            throw CaptureError.noVideoPort
        }
        let connection = AVCaptureConnection(inputPorts: [videoPort], output: movieOutput)
        guard multiCamSession.canAddConnection(connection) else {
            throw CaptureError.cannotAddConnection
        }
        multiCamSession.addConnection(connection)

        // Use ProRes if this device supports it in this format - far better
        // for downstream undistort/color work than H.264 would be.
        if movieOutput.availableVideoCodecTypes.contains(.proRes422) {
            movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.proRes422],
                                           for: connection)
        }
    }

    /// Set from the didStartRecordingTo delegate callback below - there is no
    /// such property on AVCaptureMovieFileOutput itself, so we capture the
    /// host-clock time ourselves at the moment recording actually begins.
    private(set) var recordingStartHostTime: CMTime = .zero

    func startRecording(to url: URL) {
        multiCamSession.startRunning()
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
    }

    func stopRecording() {
        movieOutput.stopRecording()
        isRecording = false
    }

    enum CaptureError: Error {
        case multiCamUnsupported, cannotAddInput, formatUnavailable
        case cannotAddOutput, noVideoPort, cannotAddConnection
    }
}

extension MultiCamCaptureSession: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                     didStartRecordingTo fileURL: URL,
                     from connections: [AVCaptureConnection]) {
        recordingStartHostTime = CMClockGetTime(CMClockGetHostTimeClock())
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                     didFinishRecordingTo outputFileURL: URL,
                     from connections: [AVCaptureConnection],
                     error: Error?) {
        isRecording = false
        if let error = error {
            print("⚠️ Recording finished with error: \(error)")
        }
    }
}

// MARK: - Post-capture: resample pose to each video frame's exact timestamp

/// Call this once recording + AR tracking are both done. `videoFrameTimestamps`
/// are each output frame's presentationTimeStamp converted to the same host
/// clock as `TrackedFrame.hostTimestamp`. Returns one pose per video frame,
/// linearly interpolated in position and SLERPed in rotation between the two
/// nearest ARKit samples - this is what actually removes the "frames don't
/// line up" error between the two independent capture streams.
func resamplePoses(track: [TrackedFrame], toVideoFrameTimestamps videoFrameTimestamps: [Double]) -> [TrackedFrame] {
    guard !track.isEmpty else { return [] }
    var result: [TrackedFrame] = []
    var searchIdx = 0

    for vt in videoFrameTimestamps {
        while searchIdx < track.count - 1 && track[searchIdx + 1].hostTimestamp < vt {
            searchIdx += 1
        }
        let a = track[searchIdx]
        let b = track[min(searchIdx + 1, track.count - 1)]
        let span = max(b.hostTimestamp - a.hostTimestamp, 1e-6)
        let alpha = Float(min(max((vt - a.hostTimestamp) / span, 0.0), 1.0))

        let interpolated = interpolateTransform(a.transform, b.transform, alpha: alpha)
        result.append(TrackedFrame(
            hostTimestamp: vt,
            transform: interpolated,
            intrinsics: a.intrinsics, // intrinsics don't change frame-to-frame with autofocus off
            imageWidth: a.imageWidth,
            imageHeight: a.imageHeight,
            exposureDuration: a.exposureDuration,
            trackingState: (alpha < 0.5 ? a.trackingState : b.trackingState)
        ))
    }
    return result
}

private func interpolateTransform(_ a: [Float], _ b: [Float], alpha: Float) -> [Float] {
    // Decompose into position (cols 3) + rotation (cols 0-2), lerp position,
    // slerp rotation via simd_quatf, recompose. Kept explicit rather than
    // hidden in a matrix lerp, which is NOT valid for rotation components.
    let posA = SIMD3<Float>(a[12], a[13], a[14])
    let posB = SIMD3<Float>(b[12], b[13], b[14])
    let pos = simd_mix(posA, posB, SIMD3<Float>(repeating: alpha))

    let rotA = simd_quatf(simd_float3x3(columns: (
        SIMD3(a[0], a[1], a[2]), SIMD3(a[4], a[5], a[6]), SIMD3(a[8], a[9], a[10])
    )))
    let rotB = simd_quatf(simd_float3x3(columns: (
        SIMD3(b[0], b[1], b[2]), SIMD3(b[4], b[5], b[6]), SIMD3(b[8], b[9], b[10])
    )))
    let rot = simd_slerp(rotA, rotB, alpha)
    let R = simd_float3x3(rot)

    return [
        R.columns.0.x, R.columns.0.y, R.columns.0.z, 0,
        R.columns.1.x, R.columns.1.y, R.columns.1.z, 0,
        R.columns.2.x, R.columns.2.y, R.columns.2.z, 0,
        pos.x, pos.y, pos.z, 1
    ]
}