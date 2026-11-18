//
//  VideoRecorder.swift
//  LidarCamTrack
//
//  Writes ARKit's own camera frames (ARFrame.capturedImage) to a .mov file.
//  Because the pixels and the pose come from the SAME ARFrame, video frame N
//  and track entry N are guaranteed to line up - no clock resampling needed.
//
//  Video timestamps are the ARFrame host-clock timestamps, so
//  (frame.hostTimestamp - firstFrame.hostTimestamp) == time in the video file.
//

import AVFoundation
import CoreVideo

final class VideoRecorder {

    let url: URL
    private(set) var writtenFrames = 0
    private(set) var droppedFrames = 0
    private(set) var setupError: String?

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    init(url: URL) {
        self.url = url
    }

    /// Returns true if the frame was accepted by the encoder. The caller only
    /// logs a pose for accepted frames so video and track stay 1:1.
    @discardableResult
    func append(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) -> Bool {
        let pts = CMTime(seconds: timestamp, preferredTimescale: 60000)

        if writer == nil && setupError == nil {
            setUp(width: CVPixelBufferGetWidth(pixelBuffer),
                  height: CVPixelBufferGetHeight(pixelBuffer),
                  firstPTS: pts)
        }
        guard let writer = self.writer,
              let input = self.input,
              let adaptor = self.adaptor,
              writer.status == .writing else {
            return false
        }
        guard input.isReadyForMoreMediaData else {
            droppedFrames += 1
            return false
        }
        if adaptor.append(pixelBuffer, withPresentationTime: pts) {
            writtenFrames += 1
            return true
        } else {
            droppedFrames += 1
            return false
        }
    }

    func finish(completion: @escaping () -> Void) {
        guard let writer = self.writer, writer.status == .writing else {
            completion()
            return
        }
        input?.markAsFinished()
        writer.finishWriting {
            completion()
        }
    }

    private func setUp(width: Int, height: Int, firstPTS: CMTime) {
        do {
            try? FileManager.default.removeItem(at: url)
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)

            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 60_000_000
                ]
            ]
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            inp.expectsMediaDataInRealTime = true

            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp,
                                                          sourcePixelBufferAttributes: nil)
            guard w.canAdd(inp) else {
                setupError = "Video writer can't accept the video input."
                return
            }
            w.add(inp)
            guard w.startWriting() else {
                setupError = "Video writer failed to start: \(w.error?.localizedDescription ?? "unknown error")"
                return
            }
            w.startSession(atSourceTime: firstPTS)

            writer = w
            input = inp
            adaptor = ad
        } catch {
            setupError = "Video writer setup failed: \(error.localizedDescription)"
        }
    }
}
