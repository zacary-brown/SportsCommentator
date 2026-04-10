import AVFoundation
import AVKit
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
internal import Combine

enum PipelineState: Equatable {
    case idle
    case running(step: PipelineStep)
    case failed(message: String, recoverableStep: PipelineStep?)
    case completed(outputURL: URL, transcript: String)
}

enum PipelineStep: Equatable {
    case importing
    case transcribing
    case generatingVoice
    case composing
}

enum PipelineError: Error {
    case importFailed
    case transcriptionFailed
    case voiceGenerationFailed
    case compositionFailed
    case cancelled
}

private enum StitchError: LocalizedError {
    case invalidVideoDuration
    case invalidAudioDuration
    case noVideoTrack
    case noAudioTrack
    case exportSessionFailed
    case couldNotAddCompositionTracks

    var errorDescription: String? {
        switch self {
        case .invalidVideoDuration:
            return "Could not read a valid duration for the video."
        case .invalidAudioDuration:
            return "Could not read a valid duration for the recorded audio."
        case .noVideoTrack:
            return "The video file has no video track."
        case .noAudioTrack:
            return "The audio file has no audio track."
        case .exportSessionFailed:
            return "Could not create a video export session."
        case .couldNotAddCompositionTracks:
            return "Could not build the composed video timeline."
        }
    }
}

@MainActor
final class PipelineViewModel: ObservableObject {
    @Published var selectedItem: PhotosPickerItem?
    @Published var sourceVideoURL: URL?
    @Published var outputVideoURL: URL?
    @Published var transcript: String = ""
    @Published var state: PipelineState = .idle

    @Published private(set) var isAudioRecording = false
    @Published var recordedAudioURL: URL? = nil
    @Published var audioRecordingError: String?

    // private let orchestrator: PipelineOrchestrator
    private var pipelineTask: Task<Void, Never>?
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?

//    init(orchestrator: PipelineOrchestrator) {
//        self.orchestrator = orchestrator
//    }

    func importSelectedVideo() async {
        guard let selectedItem else { return }
        state = .running(step: .importing)

        do {
            guard let movieData = try await selectedItem.loadTransferable(type: Data.self) else {
                throw PipelineError.importFailed
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("source-\(UUID().uuidString)")
                .appendingPathExtension("mp4")
            try movieData.write(to: url, options: .atomic)
            sourceVideoURL = url
            transcript = ""
            state = .idle
        } catch {
            state = .failed(message: error.localizedDescription, recoverableStep: .importing)
        }
    }
    
    func startAudioRecording() async {
        audioRecordingError = nil
        guard !isAudioRecording else { return }

        let granted = await Self.requestMicrophonePermission()
        guard granted else {
            audioRecordingError = "Microphone access was denied. Enable it in Settings → Privacy & Security → Microphone."
            return
        }

        do {
            try activateRecordingSession()
        } catch {
            audioRecordingError = error.localizedDescription
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("commentary-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.prepareToRecord()
            guard recorder.record() else {
                audioRecordingError = "Could not start recording."
                return
            }
            audioRecorder = recorder
            isAudioRecording = true
        } catch {
            audioRecordingError = error.localizedDescription
        }
    }

    func stopAudioRecording() {
        guard isAudioRecording else { return }
        let url = audioRecorder?.url
        audioRecorder?.stop()
        audioRecorder = nil
        isAudioRecording = false
        recordedAudioURL = url
    }

    func playRecordedAudio() {
        guard let url = recordedAudioURL else { return }
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.play()
    }

    private static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func activateRecordingSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
        try session.setActive(true)
    }
    
    func stitchVideo() {
        guard let videoURL = sourceVideoURL, let audioURL = recordedAudioURL else { return }
        pipelineTask?.cancel()
        state = .running(step: .composing)
        let transcriptSnapshot = transcript
        pipelineTask = Task { [weak self, videoURL, audioURL, transcriptSnapshot] in
            do {
                let outputURL = try await Self.performStitch(videoURL: videoURL, audioURL: audioURL)
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    outputVideoURL = outputURL
                    state = .completed(outputURL: outputURL, transcript: transcriptSnapshot)
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.state = .idle
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    state = .failed(message: error.localizedDescription, recoverableStep: .composing)
                }
            }
        }
    }

    private nonisolated static func performStitch(videoURL: URL, audioURL: URL) async throws -> URL {
        let videoAsset = AVURLAsset(url: videoURL)
        let commentaryAsset = AVURLAsset(url: audioURL)

        let videoDuration = try await videoAsset.load(.duration)
        guard videoDuration.isValid, !videoDuration.isIndefinite else {
            throw StitchError.invalidVideoDuration
        }

        let commentaryDuration = try await commentaryAsset.load(.duration)
        guard commentaryDuration.isValid, !commentaryDuration.isIndefinite, commentaryDuration.seconds > 0 else {
            throw StitchError.invalidAudioDuration
        }

        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let originalAudioTracks = try await videoAsset.loadTracks(withMediaType: .audio)
        let commentaryTracks = try await commentaryAsset.loadTracks(withMediaType: .audio)

        guard let sourceVideoTrack = videoTracks.first else {
            throw StitchError.noVideoTrack
        }
        guard let commentaryTrack = commentaryTracks.first else {
            throw StitchError.noAudioTrack
        }

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compOriginalAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compCommentaryAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StitchError.couldNotAddCompositionTracks
        }

        let videoRange = CMTimeRange(start: .zero, duration: videoDuration)
        try compVideo.insertTimeRange(videoRange, of: sourceVideoTrack, at: .zero)

        if let originalTrack = originalAudioTracks.first {
            try compOriginalAudio.insertTimeRange(videoRange, of: originalTrack, at: .zero)
        }

        let commentaryInsertDuration = CMTimeMinimum(commentaryAsset.duration, videoAsset.duration)
        let commentaryRange = CMTimeRange(start: .zero, duration: commentaryAsset.duration)
        try compCommentaryAudio.insertTimeRange(commentaryRange, of: commentaryTrack, at: .zero)

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw StitchError.exportSessionFailed
        }

        // Mix: original video audio at 50%, commentary at 100%.
        let audioMix = AVMutableAudioMix()
        var params: [AVMutableAudioMixInputParameters] = []

        if originalAudioTracks.first != nil {
            let originalParams = AVMutableAudioMixInputParameters(track: compOriginalAudio)
            originalParams.setVolume(0.5, at: .zero)
            params.append(originalParams)
        }

        let commentaryParams = AVMutableAudioMixInputParameters(track: compCommentaryAudio)
        commentaryParams.setVolume(1.0, at: .zero)
        params.append(commentaryParams)

        audioMix.inputParameters = params
        exportSession.audioMix = audioMix

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stitched-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4

        try await exportSession.export(to: outputURL, as: .mp4)
        return outputURL
    }

    // func runPipeline() {
    //     guard let sourceVideoURL else { return }
    //     pipelineTask?.cancel()
    //     outputVideoURL = nil
    //     transcript = ""

    //     pipelineTask = Task {
    //         do {
    //             let job = try await orchestrator.run(sourceVideoURL: sourceVideoURL) { [weak self] newState in
    //                 Task { @MainActor in
    //                     self?.state = newState
    //                 }
    //             }
    //             transcript = job.transcript
    //             outputVideoURL = job.outputVideoURL
    //             state = .completed(outputURL: job.outputVideoURL, transcript: job.transcript)
    //         } catch is CancellationError {
    //             state = .failed(message: PipelineError.cancelled.localizedDescription, recoverableStep: nil)
    //         } catch {
    //             state = .failed(message: error.localizedDescription, recoverableStep: retryStep(for: error))
    //         }
    //     }
    // }

    // func cancelPipeline() {
    //     pipelineTask?.cancel()
    // }

    func retry() {
        print("Retry (Does Nothing)")
        // runPipeline()
    }

    func saveToPhotos() async {
        guard let outputVideoURL else { return }
        _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputVideoURL)
            }
        } catch {
            state = .failed(message: "Saved export failed: \(error.localizedDescription)", recoverableStep: nil)
        }
    }

    private func retryStep(for error: Error) -> PipelineStep? {
        switch error {
        case PipelineError.transcriptionFailed:
            return .transcribing
        case PipelineError.voiceGenerationFailed:
            return .generatingVoice
        case PipelineError.compositionFailed:
            return .composing
        default:
            return nil
        }
    }
}
