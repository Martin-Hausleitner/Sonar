import Foundation
import Combine

#if canImport(WhisperKit)
import WhisperKit
#endif

/// Manages on-device Whisper model downloads and local storage.
/// Models are stored in Application Support/SonarModels/ and survive app updates.
@MainActor
final class LocalModelManager: ObservableObject {

    static let shared = LocalModelManager()

    private static let legacyModelIDMap = [
        "ggml-tiny-en": "whisperkit-tiny-en",
        "ggml-base-en": "whisperkit-base-en",
        "ggml-small-en": "whisperkit-small-en",
    ]

    struct ModelInfo: Identifiable {
        let id: String
        let displayName: String
        let sourceURL: URL
        let approxMB: Int
        let whisperKitVariant: String
        var metadataFilename: String { "\(id).json" }

        /// Legacy tests and cleanup still refer to a model "filename"; keep this
        /// as the metadata filename because WhisperKit models are directories.
        var filename: String { metadataFilename }
    }

    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready(Int64)
        case failed(String)
    }

    static let availableModels: [ModelInfo] = [
        ModelInfo(
            id: "whisperkit-tiny-en",
            displayName: "Whisper Tiny EN",
            sourceURL: URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-tiny.en")!,
            approxMB: 75,
            whisperKitVariant: "openai_whisper-tiny.en"
        ),
        ModelInfo(
            id: "whisperkit-base-en",
            displayName: "Whisper Base EN",
            sourceURL: URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-base.en")!,
            approxMB: 142,
            whisperKitVariant: "openai_whisper-base.en"
        ),
        ModelInfo(
            id: "whisperkit-small-en",
            displayName: "Whisper Small EN",
            sourceURL: URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-small.en")!,
            approxMB: 466,
            whisperKitVariant: "openai_whisper-small.en"
        ),
    ]

    @Published var states: [String: DownloadState] = [:]

    var selectedModelID: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "sonar.localmodel.selected") ?? ""
            return Self.legacyModelIDMap[stored] ?? stored
        }
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
        guard let metadata = readMetadata(for: model) else { return nil }
        let url = URL(fileURLWithPath: metadata.folderPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ model: ModelInfo) {
        if case .downloading = states[model.id] ?? .notDownloaded { return }
        states[model.id] = .downloading(0)

        Task {
            do {
                #if canImport(WhisperKit)
                let folder = try await WhisperKit.download(
                    variant: model.whisperKitVariant,
                    downloadBase: modelsDir,
                    progressCallback: { [weak self] progress in
                        let fraction = progress.fractionCompleted.isFinite ? progress.fractionCompleted : 0
                        Task { @MainActor [weak self] in
                            self?.states[model.id] = .downloading(fraction)
                        }
                    }
                )
                let size = folderSize(folder)
                try writeMetadata(
                    LocalModelMetadata(
                        modelID: model.id,
                        variant: model.whisperKitVariant,
                        folderPath: folder.path,
                        size: size
                    ),
                    for: model
                )
                states[model.id] = .ready(size)
                #else
                states[model.id] = .failed("WhisperKit ist nicht verfügbar")
                #endif
            } catch {
                states[model.id] = .failed(error.localizedDescription)
            }
        }
    }

    func delete(_ model: ModelInfo) {
        if let metadata = readMetadata(for: model) {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: metadata.folderPath))
        }
        try? FileManager.default.removeItem(at: metadataURL(for: model))
        try? FileManager.default.removeItem(at: modelsDir.appendingPathComponent("\(model.id).bin"))
        states[model.id] = .notDownloaded
        if selectedModelID == model.id { selectedModelID = "" }
    }

    // MARK: - Helpers

    private func refreshState(_ model: ModelInfo) {
        if let url = localURL(for: model) {
            let size = readMetadata(for: model)?.size ?? folderSize(url)
            states[model.id] = .ready(size)
        } else {
            states[model.id] = .notDownloaded
        }
    }

    private func metadataURL(for model: ModelInfo) -> URL {
        modelsDir.appendingPathComponent(model.metadataFilename)
    }

    private func readMetadata(for model: ModelInfo) -> LocalModelMetadata? {
        let url = metadataURL(for: model)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LocalModelMetadata.self, from: data)
    }

    private func writeMetadata(_ metadata: LocalModelMetadata, for model: ModelInfo) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL(for: model), options: .atomic)
    }

    private func folderSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

private struct LocalModelMetadata: Codable {
    let modelID: String
    let variant: String
    let folderPath: String
    let size: Int64
}
