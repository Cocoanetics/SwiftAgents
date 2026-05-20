import SwiftUI

struct SettingsView: View {
    let endpoint: String
    let gatewayToken: String

    @Environment(\.dismiss) private var dismiss
    @AppStorage("selectedModel") private var selectedModel = "openclaw/default"

    @State private var availableModels: [String] = []
    @State private var isFetchingModels = false
    @State private var fetchError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Endpoint", value: endpoint)
                        .font(.footnote)
                } header: {
                    Text("OpenClaw Endpoint")
                } footer: {
                    Text("Configured via Config/Local.xcconfig.")
                }

                Section {
                    if availableModels.isEmpty {
                        LabeledContent("Model", value: selectedModel)
                    } else {
                        Picker("Model", selection: $selectedModel) {
                            ForEach(availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }

                    if let fetchError {
                        Text(fetchError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Model")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await fetchModels()
            }
        }
    }

    private func fetchModels() async {
        let base = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/v1/models") else {
            fetchError = "Invalid endpoint URL."
            return
        }

        isFetchingModels = true
        fetchError = nil
        defer { isFetchingModels = false }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(gatewayToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                fetchError = "Server returned \(code)."
                return
            }

            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            let ids = decoded.data.map(\.id).sorted()
            availableModels = ids

            if !ids.contains(selectedModel) {
                selectedModel = ids.first(where: { $0 == "openclaw/default" }) ?? ids.first ?? "openclaw/default"
            }
        } catch {
            fetchError = error.localizedDescription
        }
    }
}

private struct ModelsResponse: Decodable {
    let data: [ModelEntry]
}

private struct ModelEntry: Decodable {
    let id: String
}
