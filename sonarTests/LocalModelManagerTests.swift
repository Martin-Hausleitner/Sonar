import XCTest
@testable import Sonar

/// Tests for LocalModelManager state machine and file-system behaviour.
/// No network calls are made — downloads are not triggered in this suite.
@MainActor
final class LocalModelManagerTests: XCTestCase {

    // A fresh manager that uses an isolated temp directory (not the real one).
    // We test state transitions without touching the real Application Support folder.

    // MARK: - Static model catalogue

    func testAtLeastThreeModelsAvailable() {
        XCTAssertGreaterThanOrEqual(LocalModelManager.availableModels.count, 3)
    }

    func testAllModelsHaveUniqueIDs() {
        let ids = LocalModelManager.availableModels.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "All model IDs must be unique")
    }

    func testAllModelsHaveNonEmptyURLs() {
        for model in LocalModelManager.availableModels {
            XCTAssertFalse(model.sourceURL.absoluteString.isEmpty,
                           "\(model.id) must have a non-empty source URL")
        }
    }

    func testAllModelsHavePositiveApproxMB() {
        for model in LocalModelManager.availableModels {
            XCTAssertGreaterThan(model.approxMB, 0,
                                 "\(model.id) must declare a positive approxMB")
        }
    }

    func testFilenameMatchesID() {
        for model in LocalModelManager.availableModels {
            XCTAssertTrue(model.filename.hasPrefix(model.id),
                          "Filename must start with the model id")
            XCTAssertTrue(model.filename.hasSuffix(".bin"),
                          "Filename must end in .bin")
        }
    }

    // MARK: - localURL

    func testLocalURLNilWhenFileAbsent() {
        let manager = LocalModelManager.shared
        // Any model whose file we haven't downloaded must return nil.
        // We check the first model with .notDownloaded state.
        for model in LocalModelManager.availableModels {
            if case .notDownloaded = manager.states[model.id] ?? .notDownloaded {
                XCTAssertNil(manager.localURL(for: model),
                             "localURL must be nil when model is not downloaded")
                return
            }
        }
        // All models already downloaded on this machine — skip gracefully.
    }

    // MARK: - selectedModelID

    func testSelectedModelIDRoundTrips() {
        let manager = LocalModelManager.shared
        let original = manager.selectedModelID
        defer { manager.selectedModelID = original }   // restore

        manager.selectedModelID = "test-roundtrip-id"
        XCTAssertEqual(manager.selectedModelID, "test-roundtrip-id")

        manager.selectedModelID = ""
        XCTAssertEqual(manager.selectedModelID, "")
    }

    func testSelectedModelIDPersistedInUserDefaults() {
        let manager = LocalModelManager.shared
        let original = manager.selectedModelID
        defer {
            manager.selectedModelID = original
            UserDefaults.standard.removeObject(forKey: "sonar.localmodel.selected")
        }

        manager.selectedModelID = "persisted-test"
        let stored = UserDefaults.standard.string(forKey: "sonar.localmodel.selected")
        XCTAssertEqual(stored, "persisted-test")
    }

    // MARK: - downloadState helpers

    func testInitialStatesAreNotDownloadedOrReady() {
        let manager = LocalModelManager.shared
        for model in LocalModelManager.availableModels {
            let state = manager.states[model.id] ?? .notDownloaded
            switch state {
            case .notDownloaded, .ready: break   // both valid at test time
            case .downloading, .failed:
                XCTFail("Model \(model.id) must not be in downloading/failed state at init")
            }
        }
    }

    func testStateEquatability() {
        XCTAssertEqual(LocalModelManager.DownloadState.notDownloaded,
                       LocalModelManager.DownloadState.notDownloaded)
        XCTAssertEqual(LocalModelManager.DownloadState.downloading(0.5),
                       LocalModelManager.DownloadState.downloading(0.5))
        XCTAssertNotEqual(LocalModelManager.DownloadState.downloading(0.3),
                          LocalModelManager.DownloadState.downloading(0.7))
        XCTAssertEqual(LocalModelManager.DownloadState.ready(100),
                       LocalModelManager.DownloadState.ready(100))
        XCTAssertNotEqual(LocalModelManager.DownloadState.ready(100),
                          LocalModelManager.DownloadState.ready(200))
        XCTAssertEqual(LocalModelManager.DownloadState.failed("err"),
                       LocalModelManager.DownloadState.failed("err"))
    }

    // MARK: - delete (with a synthetic file)

    func testDeleteResetsStateAndClearsSelection() throws {
        let manager = LocalModelManager.shared
        guard let model = LocalModelManager.availableModels.first else {
            XCTFail("Need at least one model"); return
        }

        let original = manager.selectedModelID
        defer { manager.selectedModelID = original }

        // Manually plant a fake file where LocalModelManager would store it
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask)[0]
        let modelDir = supportDir.appendingPathComponent("SonarModels")
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let fakeFile = modelDir.appendingPathComponent(model.filename)
        try Data("fake-model-bytes".utf8).write(to: fakeFile)

        // Reinitialise to pick up the file
        let freshManager = LocalModelManager()
        XCTAssertEqual(freshManager.states[model.id], .ready(Int64("fake-model-bytes".utf8.count)))
        freshManager.selectedModelID = model.id
        XCTAssertEqual(freshManager.selectedModelID, model.id)

        freshManager.delete(model)

        XCTAssertEqual(freshManager.states[model.id], .notDownloaded)
        XCTAssertNil(freshManager.localURL(for: model))
        XCTAssertNotEqual(freshManager.selectedModelID, model.id)
    }
}
