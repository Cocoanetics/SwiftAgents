import SwiftUI

struct ConversationView: View {
    @ObservedObject var viewModel: ConversationViewModel
    @State private var showingInfo = false
    @State private var showingSettings = false
    @State private var revealedIDs: Set<String> = []
    @State private var pendingReveal: Set<String> = []

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                transcriptView
                callButton
                    .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("RealtimeVoiceAgent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.configuration.openclawConfigured {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityIdentifier("settings-button")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityIdentifier("info-button")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(
                    endpoint: viewModel.configuration.openclawEndpoint ?? "",
                    gatewayToken: viewModel.configuration.openclawToken ?? ""
                )
            }
            .sheet(isPresented: $showingInfo) {
                InfoView(viewModel: viewModel)
            }
            .sheet(item: $viewModel.showFileContent) { file in
                FileViewerSheet(file: file)
            }
        }
    }

    // MARK: - Transcript

    private var transcriptView: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                if viewModel.transcriptEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No transcript yet.")
                            .font(.subheadline.weight(.semibold))
                        Text("Start the voice session and speak to stream microphone audio to the realtime session. User and assistant transcript updates appear here incrementally.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .accessibilityIdentifier("empty-transcript-state")
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.transcriptEntries) { entry in
                            if revealedIDs.contains(entry.id) {
                                TranscriptBubble(entry: entry)
                                    .id(entry.id)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: entry.role == .user ? .trailing : .leading).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                            }
                        }
                        Color.clear
                            .frame(height: 120)
                            .id("bottom-anchor")
                    }
                    .accessibilityIdentifier("transcript-list")
                    .padding(18)
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: viewModel.transcriptEntries.map(\.id)) { oldIDs, newIDs in
                let added = Set(newIDs).subtracting(Set(oldIDs))
                guard !added.isEmpty else { return }

                pendingReveal.formUnion(added)

                // Phase 1: scroll up to make room
                withAnimation(.easeOut(duration: 0.25)) {
                    scrollProxy.scrollTo("bottom-anchor", anchor: .bottom)
                }

                // Phase 2: reveal the bubble with a slide transition
                Task {
                    try? await Task.sleep(for: .milliseconds(270))
                    let toReveal = pendingReveal
                    pendingReveal.removeAll()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        revealedIDs.formUnion(toReveal)
                    }
                }
            }
            .onChange(of: viewModel.transcriptEntries) { _, _ in
                // Keep scrolled to bottom as text grows
                withAnimation(.easeOut(duration: 0.15)) {
                    scrollProxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }
            .onAppear {
                revealedIDs = Set(viewModel.transcriptEntries.map(\.id))
            }
        }
    }

    // MARK: - Floating Call Button

    private var callButton: some View {
        Group {
            if viewModel.canStop {
                Button {
                    Task { await viewModel.stopConversation() }
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(.red, in: Circle())
                        .shadow(color: .red.opacity(0.4), radius: 8, y: 4)
                }
                .accessibilityIdentifier("hang-up-button")
            } else {
                Button {
                    Task { await viewModel.startConversation() }
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Color(red: 0.11, green: 0.38, blue: 0.53), in: Circle())
                        .shadow(color: Color(red: 0.11, green: 0.38, blue: 0.53).opacity(0.4), radius: 8, y: 4)
                }
                .disabled(!viewModel.canStart)
                .opacity(viewModel.canStart ? 1 : 0.5)
                .accessibilityIdentifier("call-assistant-button")
            }
        }
    }

    // MARK: - Helpers

}

// MARK: - Info View (Sheet)

private struct InfoView: View {
    @ObservedObject var viewModel: ConversationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingShareSheet = false

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(viewModel.connectionState.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(statusColor)
                    }
                    .accessibilityIdentifier("connection-state-label")

                    if let startupIssue = viewModel.configuration.startupIssue {
                        Text(startupIssue)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Configuration") {
                    LabeledContent("Auth", value: viewModel.configuration.authModeDescription)
                    LabeledContent("Model", value: viewModel.configuration.model)
                    LabeledContent("Voice", value: viewModel.configuration.voice)
                    LabeledContent("VAD", value: viewModel.configuration.useServerVAD ? "Semantic" : "Manual")
                }

                if viewModel.showsManualRouteToggle || viewModel.connectionState.isLive || viewModel.connectionState.isBusy {
                    Section("Audio") {
                        if viewModel.showsManualRouteToggle {
                            Button {
                                viewModel.togglePreferredOutputRoute()
                            } label: {
                                Label(viewModel.preferredOutputRoute.title, systemImage: viewModel.preferredOutputRoute == .speaker ? "speaker.wave.3.fill" : "phone.fill")
                            }
                            .accessibilityIdentifier("audio-route-toggle-button")
                        } else {
                            Label("Route: \(viewModel.currentOutputRoute.title)", systemImage: viewModel.currentOutputRoute == .speaker ? "speaker.wave.3.fill" : "phone.fill")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("audio-route-label")
                        }
                    }
                }

                Section("Documents") {
                    Text(viewModel.documentsPath)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    
                    if viewModel.documentsURL != nil {
                        Button {
                            showingShareSheet = true
                        } label: {
                            Label("Share Documents Folder", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if !viewModel.statusMessages.isEmpty {
                    Section("Log") {
                        ForEach(Array(viewModel.statusMessages.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let url = viewModel.documentsURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    private var statusColor: Color {
        switch viewModel.connectionState {
        case .idle, .disconnected:
            return .gray
        case .connecting, .disconnecting:
            return .orange
        case .connected:
            return .green
        case .failed:
            return .red
        }
    }
}

// MARK: - Typing Dots

private struct TypingDotsView: View {
    let dotColor: Color
    @State private var activeIndex = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(dotColor.opacity(activeIndex == index ? 1 : 0.35))
                    .frame(width: 8, height: 8)
                    .scaleEffect(activeIndex == index ? 1.1 : 0.9)
                    .animation(.easeInOut(duration: 0.2), value: activeIndex)
            }
        }
        .onAppear {
            activeIndex = 0
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(240))
                activeIndex = (activeIndex + 1) % 3
            }
        }
    }
}

// MARK: - Word Reveal Text

/// Displays text word-by-word, with each new word fading in.
/// Tracks which words have already appeared so only genuinely new words animate.
private struct WordRevealText: View {
    let text: String

    @State private var revealedCount: Int = 0

    private var words: [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == " " || $0 == "\n" })
            .map(String.init)
    }

    var body: some View {
        let currentWords = words
        FlowLayout(spacing: 4) {
            ForEach(Array(currentWords.enumerated()), id: \.offset) { index, word in
                Text(word.hasSuffix("\n") || word.contains("\n") ? word : word)
                    .opacity(index < revealedCount ? 1 : 0)
                    .animation(.easeIn(duration: 0.15), value: revealedCount)
            }
        }
        .onChange(of: currentWords.count) { _, newCount in
            if newCount > revealedCount {
                withAnimation(.easeIn(duration: 0.15)) {
                    revealedCount = newCount
                }
            }
        }
        .onAppear {
            revealedCount = words.count
        }
    }
}

/// Simple flow layout that wraps content like text.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        guard !rows.isEmpty else { return .zero }

        let height = rows.enumerated().reduce(CGFloat.zero) { result, item in
            let rowHeight = item.element.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            return result + rowHeight + (item.offset > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX

            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}

// MARK: - Transcript Bubble

private struct TranscriptBubble: View {
    let entry: TranscriptEntry
    @State private var isExpanded = false

    var body: some View {
        if entry.role == .tool {
            toolCallView
        } else {
            messageBubble
        }
    }

    // MARK: - Tool Call (compact inline style, tap to expand)

    private var toolCallView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption2)
                    .foregroundStyle(.green.opacity(0.7))
                Text(entry.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 2)
                if entry.fullOutput != nil {
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.6))
                }
            }
            if isExpanded, let fullOutput = entry.fullOutput {
                Text(fullOutput)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary.opacity(0.8))
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard entry.fullOutput != nil else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }

    // MARK: - Message Bubble (user / assistant / system)

    private var messageBubble: some View {
        HStack {
            if entry.role == .user {
                Spacer(minLength: 40)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.role.title)
                        .font(.caption.weight(.semibold))
                }

                if entry.text.isEmpty && !entry.isFinal && entry.role == .user {
                    TypingDotsView(dotColor: foregroundColor)
                } else if entry.text.isEmpty && entry.role == .assistant && !entry.isFinal {
                    TypingDotsView(dotColor: foregroundColor)
                } else {
                    WordRevealText(text: entry.text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .foregroundStyle(foregroundColor)

            if entry.role != .user {
                Spacer(minLength: 40)
            }
        }
    }

    private var backgroundColor: Color {
        switch entry.role {
        case .user:
            return Color(red: 0.16, green: 0.45, blue: 0.57)
        case .assistant:
            return Color(.secondarySystemGroupedBackground)
        case .tool, .system:
            return Color(.systemGray5)
        }
    }

    private var foregroundColor: Color {
        entry.role == .user ? .white : .primary
    }
}

// MARK: - File Viewer Sheet

private struct FileViewerSheet: View {
    let file: ShowFileContent
    @Environment(\.dismiss) private var dismiss
    @State private var showingShareSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(LocalizedStringKey(file.content))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(file.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                ShareSheet(items: [file.content])
            }
        }
    }
}

// MARK: - Share Sheet

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
