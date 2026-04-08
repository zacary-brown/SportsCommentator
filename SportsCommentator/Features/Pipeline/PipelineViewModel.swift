import AVKit
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
internal import Combine

enum PipelineViewModelError: Error {
    case noVideoData
}

@MainActor
final class PipelineViewModel: ObservableObject {
    @Published var selectedItem: PhotosPickerItem?
    @Published var sourceVideoURL: URL?
    @Published var outputVideoURL: URL?

    func importSelectedVideo() async {
        guard let selectedItem else { return }

        do {
            guard let movieData = try await selectedItem.loadTransferable(type: Data.self) else {
                throw PipelineViewModelError.noVideoData
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("source-\(UUID().uuidString)")
                .appendingPathExtension("mp4")
            try movieData.write(to: url, options: .atomic)
            sourceVideoURL = url
        } catch {
            print("Error importing video: \(error)")
        }
    }

    func saveToPhotos() async {
        guard let outputVideoURL else { return }
        _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputVideoURL)
            }
        } catch {
            print("Error saving video to photos: \(error)")
        }
    }
}
