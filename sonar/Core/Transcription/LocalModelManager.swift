import Foundation
import Combine

/// Manages on-device Whisper model downloads and local storage.
/// Models are stored in Application Support/SonarModels/ and survive app updates.
@MainActor
final class LocalModelManager: ObservableObject {

    static let shared = LocalModelManager()

    struct ModelInfo: Identifiable {
        let id: String
        let displayName: String
        let sourceURL: URL
        let approxMB: Int
        var filename: String { "\(id).bin" }
    }

    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready(Int64)
        case failed(String)
    }

    static let availableModels: [ModelInfo] = [
        ModelInfo(
            id: "ggml-tiny-en",
            displayName: "Whisper Tiny EN",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin")!,
            approxMB: 75
        ),
        ModelInfo(
            id: "ggml-base-en",
            displayName: "Whisper Base EN",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!,
            approxMB: 142
        ),
        ModelInfo(
            id: "ggml-small-en",
            displayName: "Whisper Small EN",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")!,
            approxMB: 466
        ),
    ]

    @Published var states: [String: DownloadState] = [:]

    var selectedModelID: String {
        get { UserDefaults.standard.string(forKey: "sonar.localmodel.selected") ?? "" }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "sonar.localmodel.selected")
        }
    }

    private var modelsDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("SonarModels", isDirectory: true)
    }

    init() {
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        for model in Self.availableModels {
            refreshState(model)
        }
    }

    func localURL(for model: ModelInfo) -> URL? {
        let url = modelsDir.appendingPathComponent(model.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ model: ModelInfo) {
        if case .downloading = states[model.id] ?? .notDownloaded { return }
        states[model.id] = .downloading(0)

        let dest = modelsDir.appendingPathComponent(model.filename)
        let id   = model.id

        Task {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let delegate = DownloadDelegate(
                    onProgress: { [weak self] p in
                        Task { @MainActor [weak self] in
                            self?.states[id] = .downloading(p)
                        }
                    },
                    onComplete: { [weak self] tempURL, error in
                        Task { @MainActor [weak self] in
                            defer { cont.resume() }
                            guard let tempURL, error == nil else {
                                self?.states[id] = .failed(error?.localizedDescription ?? "Fehler")
                                return
                            }
                            do {
                                try? FileManager.default.removeItem(at: dest)
                                try FileManager.default.moveItem(at: tempURL, to: dest)
                                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
                                self?.states[id] = .ready(size)
                            } catch {
                                self?.states[id] = .failed(error.localizedDescription)
                            }
                        }
                    }
                )
                let cfg = URLSessionConfiguration.default
                cfg.timeoutIntervalForResource = 600
                let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
                session.downloadTask(with: model.sourceURL).resume()
            }
        }
    }

    func delete(_ model: ModelInfo) {
        let url = modelsDir.appendingPathComponent(model.filename)
        try? FileManager.default.removeItem(at: url)
        states[model.id] = .notDownloaded
        if selectedModelID == model.id { selectedModelID = "" }
    }

    // MARK: - Helpers

    private func refreshState(_ model: ModelInfo) {
        let url = modelsDir.appendingPathComponent(model.filename)
        if FileManager.default.fileExists(atPath: url.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            states[model.id] = .ready(size)
        } else {
            states[model.id] = .notDownloaded
        }
    }
}

// MARK: - URLSession download delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    let onComplete: (URL?, Error?) -> Void

    init(onProgress: @escaping (Double) -> Void, onComplete: @escaping (URL?, Error?) -> Void) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite total: Int64) {
        guard total > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        onComplete(location, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { onComplete(nil, error) }
    }
}
