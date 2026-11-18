//
//  CaptureCoordinator.swift
//
//  Owns the ARKit session. The camera preview + LiDAR scan start as soon as
//  the app opens (so you can frame the shot and scan the set first); the
//  Record button then starts writing 4K video + the per-frame pose track.
//  Everything is exported to a Take_ folder visible in the Files app.
//

import AVFoundation
import ARKit
import Combine

@MainActor
final class CaptureCoordinator: ObservableObject {

    @Published var isPreviewRunning = false
    @Published var isRecording = false
    @Published var showMesh = true
    @Published var trackingStatus = "Starting..."
    @Published var frameCount = 0
    @Published var meshTriangles = 0
    @Published var recordingSeconds: Double = 0
    @Published var videoFormatText = ""
    @Published var lastExportFolder: URL?
    @Published var exportSummary: String?
    @Published var errorMessage: String?

    let arTracker = ARTrackerSession()
    let lidarSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    private var recorder: VideoRecorder?
    private var statusTimer: Timer?
    private var currentSessionFolder: URL?
    private var recordingStart: Date?

    /// Called when the screen appears: asks for camera access, then starts
    /// the live preview. Safe to call more than once.
    func startPreview() {
        guard !isPreviewRunning else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                guard granted else {
                    self.errorMessage = "Camera permission denied. Enable it in Settings > LidarCamTrack."
                    return
                }
                guard !self.isPreviewRunning else { return }
                self.arTracker.start()
                self.videoFormatText = self.arTracker.videoFormatDescription
                self.isPreviewRunning = true
                self.startStatusTimer()
            }
        }
    }

    func startCapture() {
        guard isPreviewRunning, !isRecording else { return }

        let sessionFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Take_\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        currentSessionFolder = sessionFolder

        let rec = VideoRecorder(url: sessionFolder.appendingPathComponent("video_4k24.mov"))
        recorder = rec
        arTracker.recorder = rec
        arTracker.beginRecording()

        errorMessage = nil
        exportSummary = nil
        recordingStart = Date()
        recordingSeconds = 0
        isRecording = true
    }

    func stopCapture() {
        guard isRecording else { return }

        arTracker.endRecording()
        arTracker.recorder = nil
        isRecording = false

        guard let folder = currentSessionFolder else { return }
        let rec = recorder
        recorder = nil

        do {
            try arTracker.exportTrack(to: folder)
            lastExportFolder = folder
        } catch {
            errorMessage = "Export failed: \(error)"
        }

        if let setupError = rec?.setupError {
            errorMessage = setupError
        }

        let poseCount = arTracker.frames.count
        if let rec = rec {
            rec.finish { [weak self] in
                Task { @MainActor in
                    self?.exportSummary = "\(rec.writtenFrames) video frames, \(poseCount) poses, \(rec.droppedFrames) dropped"
                }
            }
        }
    }

    private func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    private func refreshStatus() {
        trackingStatus = arTracker.latestTrackingState
        frameCount = arTracker.frames.count
        meshTriangles = arTracker.meshTriangleCount
        if isRecording, let start = recordingStart {
            recordingSeconds = Date().timeIntervalSince(start)
        }
    }
}
