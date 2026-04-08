//
//  ContentView.swift
//  SportsCommentator
//
//  Created by Zacary Brown on 4/7/26.
//

import SwiftUI
import PhotosUI
import AVKit

struct ContentView: View {
    @StateObject private var viewModel: PipelineViewModel

    init(viewModel: PipelineViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Sports Commentator")
                        .font(.largeTitle.bold())

                    PhotosPicker(selection: $viewModel.selectedItem, matching: .videos) {
                        Label("Pick Video", systemImage: "video.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .onChange(of: viewModel.selectedItem) { _, _ in
                        Task { await viewModel.importSelectedVideo() }
                    }

                    if let sourceURL = viewModel.sourceVideoURL {
                        Text("Source Preview")
                            .font(.headline)
                        VideoPlayer(player: AVPlayer(url: sourceURL))
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    stateView

                    if !viewModel.transcript.isEmpty {
                        Text("Transcript")
                            .font(.headline)
                        Text(viewModel.transcript)
                            .font(.footnote)
                            .padding(12)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    if let outputURL = viewModel.outputVideoURL {
                        Text("Final Video")
                            .font(.headline)
                        VideoPlayer(player: AVPlayer(url: outputURL))
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        HStack {
                            ShareLink(item: outputURL) {
                                Label("Share/Download", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Save to Photos") {
                                Task { await viewModel.saveToPhotos() }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("MVP")
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch viewModel.state {
        case .idle:
            Button("Generate Commentary Video") {
                // viewModel.runPipeline()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.sourceVideoURL == nil)
        case .running(let step):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView()
                Text(progressText(step: step))
                    .font(.subheadline)
                Button("Cancel") {
                    // viewModel.cancelPipeline()
                }
                .buttonStyle(.bordered)
            }
        case .failed(let message, let recoverableStep):
            VStack(alignment: .leading, spacing: 8) {
                Text("Error: \(message)")
                    .foregroundStyle(.red)
                if recoverableStep != nil {
                    Button("Retry") {
                        viewModel.retry()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        case .completed:
            Text("Completed successfully.")
                .foregroundStyle(.green)
        }
    }

    private func progressText(step: PipelineStep) -> String {
        switch step {
        case .importing:
            return "Importing video..."
        case .transcribing:
            return "Transcribing video with OpenAI..."
        case .generatingVoice:
            return "Generating commentator voice with ElevenLabs..."
        case .composing:
            return "Stitching audio and video..."
        }
    }
}

#Preview {
    ContentView(
        viewModel: PipelineViewModel()
    )
}
