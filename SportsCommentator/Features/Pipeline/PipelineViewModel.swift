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

@MainActor
final class PipelineViewModel: ObservableObject {
    @Published var selectedItem: PhotosPickerItem?
    @Published var sourceVideoURL: URL?
    @Published var outputVideoURL: URL?
    @Published var transcript: String = ""
    @Published var state: PipelineState = .idle

    // private let orchestrator: PipelineOrchestrator
    private var pipelineTask: Task<Void, Never>?

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
            outputVideoURL = url
            transcript = ""
            state = .idle
        } catch {
            state = .failed(message: error.localizedDescription, recoverableStep: .importing)
        }
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
