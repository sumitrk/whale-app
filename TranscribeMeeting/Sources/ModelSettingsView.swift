import SwiftUI

struct ModelInfo: Decodable, Identifiable {
    let id:         String
    let label:      String
    let size_mb:    Int
    let downloaded: Bool
}

private struct ModelsResponse: Decodable { let models: [ModelInfo] }

struct ModelSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var models:           [ModelInfo] = []
    @State private var downloading:      Set<String> = []
    @State private var downloadProgress: [String: Double] = [:]
    @State private var error:            String?

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
                    model:            model,
                    isActive:         store.activeModelId == model.id && model.downloaded,
                    isDownloading:    downloading.contains(model.id),
                    downloadProgress: downloadProgress[model.id],
                    onSelect:         { store.activeModelId = model.id },
                    onDownload:       { Task { await download(model) } }
                )
            }
            .listStyle(.inset)
        }
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
        // Don't pre-set 0.0 — show indeterminate spinner until real progress arrives
        defer {
            downloading.remove(model.id)
            downloadProgress.removeValue(forKey: model.id)
        }

        // Poll progress while download is in-flight
        let pollTask = Task {
            while !Task.isCancelled {
                await fetchDownloadProgress(for: model.id)
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
        defer { pollTask.cancel() }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:8765/models/download")!)
        req.httpMethod = "POST"
        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.appendField("model_id", value: model.id, boundary: boundary)
        req.httpBody = body
        req.timeoutInterval = 1200

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.error = "\(model.label) failed to download — try restarting the app (error \(http.statusCode))"
                return
            }
            await fetchModels()
        } catch {
            self.error = "\(model.label) failed to download: \(error.localizedDescription)"
        }
    }

    private func fetchDownloadProgress(for modelId: String) async {
        let encoded = modelId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? modelId
        guard let url = URL(string: "http://127.0.0.1:8765/models/download-progress?model_id=\(encoded)") else { return }
        struct Resp: Decodable { let percent: Double }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let resp = try? JSONDecoder().decode(Resp.self, from: data) else { return }
        // Only switch to determinate bar once real bytes are detected
        if resp.percent > 0.01 { downloadProgress[modelId] = resp.percent }
    }
}

// MARK: - Row

struct ModelRow: View {
    let model:         ModelInfo
    let isActive:      Bool
    let isDownloading: Bool
    var downloadProgress: Double? = nil   // 0.0–1.0 when known, nil = indeterminate
    let onSelect:      () -> Void
    let onDownload:    () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.label)
                    .fontWeight(isActive ? .semibold : .regular)
                Text(formattedSize)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Spacer()

            actionView
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.downloaded && !isActive { onSelect() }
        }
    }

    @ViewBuilder
    private var actionView: some View {
        if isDownloading {
            VStack(alignment: .trailing, spacing: 4) {
                if let progress = downloadProgress {
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress)
                        .frame(width: 90)
                        .tint(.blue)
                } else {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                        Text("Downloading…").foregroundStyle(.secondary).font(.callout)
                    }
                }
            }
        } else if isActive && model.downloaded {
            Label("Active", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.blue)
                .font(.callout)
                .fontWeight(.medium)
        } else if model.downloaded {
            Button("Activate", action: onSelect)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button("Download", action: onDownload)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var formattedSize: String {
        model.size_mb >= 1000
            ? String(format: "%.1f GB", Double(model.size_mb) / 1000)
            : "\(model.size_mb) MB"
    }
}

// MARK: - Data helper

extension Data {
    mutating func appendField(_ name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append(value.data(using: .utf8)!)
        append("\r\n".data(using: .utf8)!)
        append("--\(boundary)--\r\n".data(using: .utf8)!)
    }
}
