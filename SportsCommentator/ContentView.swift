//
//  ContentView.swift
//  SportsCommentator
//
//  Created by Zacary Brown on 4/7/26.
//

import SwiftUI
import PhotosUI
import AVFoundation
import AVKit

struct ContentView: View {
    @StateObject private var viewModel: PipelineViewModel
    @State private var sourcePlayer: AVPlayer?
    @State private var outputPlayer: AVPlayer?
    @State private var recordedAudioPlayer: AVPlayer?

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

                    voiceRecordingSection

                    if sourcePlayer != nil {
                        Text("Source Preview")
                            .font(.headline)
                        VideoPlayer(player: sourcePlayer)
                            .mediaPreviewInnerClip(height: 220)
                            .onTapGesture {
                                togglePlayback(sourcePlayer)
                            }
                            .mediaPreviewCardChrome()
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

                    if outputPlayer != nil {
                        Text("Final Video")
                            .font(.headline)
                        VideoPlayer(player: outputPlayer)
                            .mediaPreviewInnerClip(height: 220)
                            .onTapGesture {
                                togglePlayback(outputPlayer)
                            }
                            .mediaPreviewCardChrome()

                        if let exportURL = viewModel.outputVideoURL {
                            HStack {
                                ShareLink(item: exportURL) {
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
                }
                .padding()
            }
            .navigationTitle("MVP")
            .onAppear {
                sourcePlayer = makePlayer(from: viewModel.sourceVideoURL)
                outputPlayer = makePlayer(from: viewModel.outputVideoURL)
                recordedAudioPlayer = makePlayer(from: viewModel.recordedAudioURL)
            }
            .onChange(of: viewModel.sourceVideoURL) { _, newValue in
                sourcePlayer?.pause()
                sourcePlayer = makePlayer(from: newValue)
            }
            .onChange(of: viewModel.outputVideoURL) { _, newValue in
                outputPlayer?.pause()
                outputPlayer = makePlayer(from: newValue)
            }
            .onChange(of: viewModel.recordedAudioURL) { _, newValue in
                recordedAudioPlayer?.pause()
                recordedAudioPlayer = makePlayer(from: newValue)
            }
        }
    }

    private var voiceRecordingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Commentary audio")
                .font(.headline)
            HStack(spacing: 12) {
                Button {
                    Task { await viewModel.startAudioRecording() }
                } label: {
                    Label("Record", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isAudioRecording)

                Button("Stop") {
                    viewModel.stopAudioRecording()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.isAudioRecording)
            }
            if viewModel.isAudioRecording {
                Label("Recording…", systemImage: "record.circle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            if let message = viewModel.audioRecordingError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if viewModel.recordedAudioURL != nil, recordedAudioPlayer != nil {
                Text("Recording preview")
                    .font(.subheadline)
                VideoPlayer(player: recordedAudioPlayer)
                    .mediaPreviewInnerClip(height: 88)
                    .onTapGesture {
                        togglePlayback(recordedAudioPlayer, preparePlaybackSession: true)
                    }
                    .mediaPreviewCardChrome()
                if let url = viewModel.recordedAudioURL {
                    ShareLink(item: url) {
                        Label("Share last recording", systemImage: "square.and.arrow.up")
                    }
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch viewModel.state {
        case .idle:
             Button("Stitch Audio and Video") {
                 viewModel.stitchVideo()
             }
             .buttonStyle(.borderedProminent)
             .disabled(viewModel.sourceVideoURL == nil || viewModel.recordedAudioURL == nil)
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

    private func makePlayer(from url: URL?) -> AVPlayer? {
        guard let url else { return nil }
        return AVPlayer(url: url)
    }

    private func togglePlayback(_ player: AVPlayer?, preparePlaybackSession: Bool = false) {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if preparePlaybackSession {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
                try? AVAudioSession.sharedInstance().setActive(true)
            }
            player.play()
        }
    }
}

private extension View {
    func mediaPreviewInnerClip(height: CGFloat) -> some View {
        self
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func mediaPreviewCardChrome() -> some View {
        self
            .padding(10)
            .background(Color.secondary.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1)
            }
    }
}

#Preview {
    ContentView(
        viewModel: PipelineViewModel()
    )
}
