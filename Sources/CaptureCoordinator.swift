//
//  CaptureCoordinator.swift
//
//  The glue that was missing: owns one ARTrackerSession + one
//  MultiCamCaptureSession, requests permissions, starts/stops both together,
//  and exports everything to a folder you can pull off via the Files app
//  (Documents is exposed - see Info.plist settings in project.yml).
//

import AVFoundation
import ARKit
import Combine

@MainActor
final class CaptureCoordinator: ObservableObject {

    @Published var isRecording = false
    @Published var trackingStatus = "Not started"
    @Published var frameCount = 0
    @Published var lastExportFolder: URL?
    @Published var errorMessage: String?

    private let arTracker = ARTrackerSession()
    private let multiCam = MultiCamCaptureSession()
    private var statusTimer: Timer?
    private var currentSessionFolder: URL?

    func requestPermissionsAndPrepare() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                Task { @MainActor in self.errorMessage = "Camera permission denied." }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.prepare() }
            }
        }
    }

    private func prepare() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            errorMessage = "No back wide-angle camera found."
            return
        }
        do {
            try multiCam.configure(using: device)
        } catch {
            errorMessage = "Multi-cam setup failed: \(error). Falls back to AR-only resolution if you proceed."
        }
    }

    func startCapture() {
        guard !isRecording else { return }

        let sessionFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Take_\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        currentSessionFolder = sessionFolder

        arTracker.start()
        multiCam.startRecording(to: sessionFolder.appendingPathComponent("video_4k24.mov"))
        isRecording = true

        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    func stopCapture() {
        guard isRecording else { return }

        multiCam.stopRecording()
        arTracker.stop()
        isRecording = false
        statusTimer?.invalidate()

        guard let folder = currentSessionFolder else { return }
        do {
            try arTracker.exportTrack(to: folder)
            lastExportFolder = folder
            trackingStatus = "Exported \(arTracker.frames.count) frames to \(folder.lastPathComponent)"
        } catch {
            errorMessage = "Export failed: \(error)"
        }
    }

    private func refreshStatus() {
        frameCount = arTracker.frames.count
        trackingStatus = arTracker.frames.last?.trackingState ?? "waiting for first frame"
    }
}
