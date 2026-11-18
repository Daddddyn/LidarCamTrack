import SwiftUI

struct ContentView: View {
    @StateObject private var coordinator = CaptureCoordinator()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // The preview is cropped to the exact shape of the recorded frame
            // (16:9), so what you see inside it is what ends up in the video.
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                ARPreviewView(session: coordinator.arTracker.arSession,
                              showMesh: coordinator.showMesh)
                    .aspectRatio(landscape ? 16.0 / 9.0 : 9.0 / 16.0, contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .ignoresSafeArea()

            VStack(spacing: 12) {
                statusPanel
                Spacer()
                bottomControls
            }
            .padding()
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true   // keep screen on while shooting
            coordinator.startPreview()
        }
    }

    // MARK: - HUD

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(coordinator.isRecording ? Color.red : Color.gray)
                    .frame(width: 10, height: 10)
                Text(coordinator.isRecording ? "REC \(timeString(coordinator.recordingSeconds))" : "Ready")
                    .font(.headline.monospacedDigit())
                Spacer()
                Text(coordinator.videoFormatText)
                    .font(.caption)
            }

            Text("Tracking: \(coordinator.trackingStatus)")
                .foregroundColor(coordinator.trackingStatus == "normal" ? Color.green : Color.orange)

            if coordinator.lidarSupported {
                Text("LiDAR mesh: \(coordinator.meshTriangles) triangles")
            } else {
                Text("No LiDAR on this device").foregroundColor(Color.orange)
            }

            if coordinator.isRecording {
                Text("Frames captured: \(coordinator.frameCount)")
            }
        }
        .font(.footnote)
        .foregroundColor(.white)
        .padding(10)
        .background(Color.black.opacity(0.55))
        .cornerRadius(12)
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            if let error = coordinator.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.footnote)
                    .padding(8)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
            }

            if let folder = coordinator.lastExportFolder, !coordinator.isRecording {
                VStack(spacing: 2) {
                    Text("Saved: \(folder.lastPathComponent)")
                    if let summary = coordinator.exportSummary {
                        Text(summary)
                    }
                    Text("Files app > On My iPhone > LidarCamTrack")
                }
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
                .padding(8)
                .background(Color.black.opacity(0.55))
                .cornerRadius(8)
            }

            if coordinator.lidarSupported {
                Toggle("Show LiDAR mesh", isOn: $coordinator.showMesh)
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(12)
            }

            Button(action: {
                if coordinator.isRecording {
                    coordinator.stopCapture()
                } else {
                    coordinator.startCapture()
                }
            }) {
                Text(coordinator.isRecording ? "Stop & Export" : "Start Recording")
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(coordinator.isRecording ? Color.red : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .disabled(!coordinator.isPreviewRunning)
            .opacity(coordinator.isPreviewRunning ? 1 : 0.5)
        }
    }

    private func timeString(_ t: Double) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
