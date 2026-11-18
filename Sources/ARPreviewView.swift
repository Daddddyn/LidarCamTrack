//
//  ARPreviewView.swift
//  LidarCamTrack
//
//  Live camera preview driven by the SAME ARSession that does the tracking
//  and recording, so what you see is exactly what's being captured. With
//  `showMesh` on, RealityKit draws the LiDAR scene-reconstruction mesh over
//  the camera image (the "space" LiDAR has scanned so far).
//

import SwiftUI
import RealityKit
import ARKit

struct ARPreviewView: UIViewRepresentable {
    let session: ARSession
    var showMesh: Bool

    func makeUIView(context: Context) -> ARView {
        // We run the session ourselves (ARTrackerSession.start), so ARView
        // must not reconfigure it.
        let view = ARView(frame: .zero,
                          cameraMode: .ar,
                          automaticallyConfigureSession: false)
        view.session = session
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        if showMesh {
            view.debugOptions.insert(.showSceneUnderstanding)
        } else {
            view.debugOptions.remove(.showSceneUnderstanding)
        }
    }
}
