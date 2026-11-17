import SwiftUI

struct ContentView: View {
    @StateObject private var coordinator = CaptureCoordinator()

    var body: some View {
        VStack(spacing: 20) {
            Text("LidarCamTrack")
                .font(.title2).bold()

            Text("Tracking: \(coordinator.trackingStatus)")
                .foregroundColor(coordinator.trackingStatus.contains("limited") ? .orange : .primary)

            Text("Frames captured: \(coordinator.frameCount)")
                .font(.caption)
                .foregroundColor(.secondary)

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
            .padding(.horizontal)

            if let folder = coordinator.lastExportFolder {
                Text("Saved to: \(folder.lastPathComponent)\nPull it off via Files app → On My iPhone → LidarCamTrack.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding()
            }

            if let error = coordinator.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.footnote)
                    .padding()
            }

            Spacer()
        }
        .padding()
        .onAppear {
            coordinator.requestPermissionsAndPrepare()
        }
    }
}
