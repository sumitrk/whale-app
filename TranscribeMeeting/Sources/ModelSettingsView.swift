import SwiftUI

struct ModelInfo: Decodable, Identifiable {
    let id:          String
    let label:       String
    let size_mb:     Int
    let downloaded:  Bool
    let languages:   String
}

private struct ModelsResponse: Decodable { let models: [ModelInfo] }

struct ModelSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var models:       [ModelInfo] = []
    @State private var downloading:  Set<String> = []
    @State private var error:        String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error {
                VStack(spacing: 8) {
                    Text(error.hasPrefix("server")
                         ? "Server not running — launch the app first."
                         : "Could not load models: \(error)")
                        .foregroundStyle(.red)
                    Button("Retry") { Task { await fetchModels() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding()
            }

            List(models) { model in
                ModelRow(
                    model:        model,
                    isActive:     store.activeModelId == model.id,
                    isDownloading: downloading.contains(model.id),
                    onSelect:     { store.activeModelId = model.id },
                    onDownload:   { Task { await download(model) } }
                )
            }
            .listStyle(.inset)
        }
        .navigationTitle("Transcription Model")
        .task { await fetchModels() }
    }

    // MARK: - Network

    private func fetchModels() async {
        do {
            let url  = URL(string: "http://127.0.0.1:8765/models")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let resp = try JSONDecoder().decode(ModelsResponse.self, from: data)
            models   = resp.models
        } catch {
            let msg = error.localizedDescription
            self.error = msg.contains("Connection refused") || msg.contains("Could not connect")
                ? "server not running"
                : msg
        }
    }

    private func download(_ model: ModelInfo) async {
        downloading.insert(model.id)
        defer { downloading.remove(model.id) }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:8765/models/download")!)
        req.httpMethod = "POST"
        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendField("model_id", value: model.id, boundary: boundary)
        req.httpBody  = body
        req.timeoutInterval = 600   // large models take a while

        do {
            let (_, _) = try await URLSession.shared.data(for: req)
            await fetchModels()     // refresh download state
        } catch {
            self.error = "Download failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Row

private struct ModelRow: View {
    let model:         ModelInfo
    let isActive:      Bool
    let isDownloading: Bool
    let onSelect:      () -> Void
    let onDownload:    () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Active indicator
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.blue : Color.secondary)
                .imageScale(.large)
                .onTapGesture { if model.downloaded { onSelect() } }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.label)
                    .fontWeight(isActive ? .semibold : .regular)
                HStack(spacing: 8) {
                    Text("\(model.size_mb) MB")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(model.languages)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            Spacer()

            if isDownloading {
                ProgressView()
                    .scaleEffect(0.7)
            } else if model.downloaded {
                Text("Ready")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Button("Download", action: onDownload)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if model.downloaded { onSelect() } }
    }
}

// MARK: - Data helper

private extension Data {
    mutating func appendField(_ name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append(value.data(using: .utf8)!)
        append("\r\n".data(using: .utf8)!)
        append("--\(boundary)--\r\n".data(using: .utf8)!)
    }
}
