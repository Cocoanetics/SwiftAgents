import SwiftUI

struct TranslatorView: View {
    @ObservedObject var viewModel: TranslatorViewModel
    @State private var showStatusLog = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                captions
                Divider()
                controls
            }
            .navigationTitle("Live Translator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showStatusLog.toggle()
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                }
            }
            .sheet(isPresented: $showStatusLog) {
                statusLog
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Translate into")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Target", selection: $viewModel.targetLanguage) {
                    ForEach(TargetLanguage.allCases) { language in
                        Text("\(language.flag) \(language.displayName)").tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 10, height: 10)
                Text(viewModel.connectionState.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case let .failed(message) = viewModel.connectionState {
                    Text("· \(message)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Spacer()
                Text("Route: \(viewModel.currentOutputRoute.title)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private var captions: some View {
        VStack(spacing: 0) {
            if !viewModel.hasTranscript {
                emptyState
            } else {
                // Translation is the primary output (what the user reads while
                // listening); the source caption is secondary context.
                CaptionPanel(
                    label: "\(viewModel.targetLanguage.flag) \(viewModel.targetLanguage.displayName)",
                    text: viewModel.translationText,
                    isPrimary: true
                )
                Divider()
                CaptionPanel(
                    label: "Heard",
                    text: viewModel.sourceText,
                    isPrimary: false
                )
                .frame(maxHeight: 180)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "earbuds")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Pop in an AirPod and tap Start.")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(
                """
                Speech around you is translated into \(viewModel.targetLanguage.displayName) \
                in your ear, with a live transcript here.
                """
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if viewModel.connectionState.isLive || viewModel.connectionState.isBusy {
                Button(role: .destructive) {
                    Task { await viewModel.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    Task { await viewModel.start() }
                } label: {
                    Label("Start", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canStart)
            }
            HStack {
                Button {
                    viewModel.togglePreferredOutputRoute()
                } label: {
                    Label("Toggle route", systemImage: "speaker.wave.2")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    viewModel.clearTranscript()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.hasTranscript)
            }
        }
        .padding()
        .background(.thinMaterial)
    }

    private var statusLog: some View {
        NavigationStack {
            List(viewModel.statusMessages.reversed()) { line in
                Text(line.text)
                    .font(.system(.caption, design: .monospaced))
            }
            .navigationTitle("Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showStatusLog = false }
                }
            }
        }
    }

    private var stateColor: Color {
        switch viewModel.connectionState {
            case .listening: return .green
            case .starting, .stopping: return .yellow
            case .failed: return .red
            case .idle: return .secondary
        }
    }
}

/// An auto-scrolling rolling caption. The translation stream has no utterance
/// boundaries, so we render the accumulated text and keep the tail in view.
private struct CaptionPanel: View {
    let label: String
    let text: String
    let isPrimary: Bool

    private let bottomAnchor = "caption-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(label.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(text.isEmpty ? "…" : text)
                        .font(isPrimary ? .title3 : .callout)
                        .fontWeight(isPrimary ? .medium : .regular)
                        .foregroundStyle(isPrimary ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding()
            }
            .onChange(of: text) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }
}
