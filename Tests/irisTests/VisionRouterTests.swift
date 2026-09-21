import XCTest
@testable import iris

final class VisionRouterTests: XCTestCase {

    /// Each test gets its OWN ConfigManager over its OWN UserDefaults suite rather than mutating
    /// `ConfigManager.shared`, which is process-global: parallel suites racing on it is the in-run
    /// half of #109 (invariant 7, #215). `VisionRouter.processTextOnlyImages` takes an injectable
    /// `config:`, so nothing here needs the singleton.
    private var config: ConfigManager!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "iris-visionrouter-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        config = ConfigManager(store: store)
        config.auxiliaryVisionEngine = ""
        config.auxiliaryVisionModel = ""
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        // removePersistentDomain does not delete the backing plist on current macOS (#178);
        // IrisDefaults sweeps stale iris-*-<UUID> plists by age, but clean up anyway.
        IrisDefaults.removeSuiteFile(named: suiteName, in: IrisDefaults.preferencesDirectory)
        config = nil
        super.tearDown()
    }

    func testPrimaryModelVisionCapabilityDetection() {
        XCTAssertTrue(VisionRouter.isVisionCapable(modelName: "gemini-2.0-flash"))
        XCTAssertTrue(VisionRouter.isVisionCapable(modelName: "claude-3-5-sonnet"))
        XCTAssertTrue(VisionRouter.isVisionCapable(modelName: "gpt-4o"))
        XCTAssertTrue(VisionRouter.isVisionCapable(modelName: "llava-v1.6"))
        XCTAssertFalse(VisionRouter.isVisionCapable(modelName: "deepseek-r1"))
        XCTAssertFalse(VisionRouter.isVisionCapable(modelName: "qwen2.5-coder"))
    }

    func testProcessTextOnlyImagesNoImages() async {
        let nonImageAttachment = FileAttachment(
            filename: "notes.txt",
            fileURL: URL(fileURLWithPath: "/tmp/notes.txt"),
            mimeType: "text/plain",
            fileSize: 100,
            category: .text
        )

        let result = await VisionRouter.processTextOnlyImages(attachments: [nonImageAttachment], config: config)
        XCTAssertEqual(result.descriptionText, "")
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testProcessTextOnlyImagesNoAuxiliaryConfigured() async {
        let imageAttachment = FileAttachment(
            filename: "screenshot.png",
            fileURL: URL(fileURLWithPath: "/tmp/screenshot.png"),
            mimeType: "image/png",
            fileSize: 500,
            category: .image
        )

        let result = await VisionRouter.processTextOnlyImages(attachments: [imageAttachment], config: config)
        XCTAssertEqual(result.descriptionText, "")
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("does not support vision and no auxiliary vision model is configured"))
    }

    func testProcessTextOnlyImagesWithAuxiliaryModel() async throws {
        // Create temp image file
        let tempDir = FileManager.default.temporaryDirectory
        let imageURL = tempDir.appendingPathComponent("test_image_\(UUID().uuidString).png")
        let dummyData = "fake image data".data(using: .utf8)!
        try dummyData.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let imageAttachment = FileAttachment(
            filename: "test_image.png",
            fileURL: imageURL,
            mimeType: "image/png",
            fileSize: Int64(dummyData.count),
            category: .image
        )

        // Mock auxiliary engine
        final class MockVisionEngine: AuxiliaryInferenceEngine, @unchecked Sendable {
            var receivedImages: [String]?
            func loadModel(config: AuxiliaryModelConfig) async throws {}
            func unloadModel() async {}
            func generate(prompt: String, jsonSchema: String?) async throws -> String {
                return "A sample diagram showing workflow."
            }
            func generate(prompt: String, jsonSchema: String?, images: [String]?) async throws -> String {
                self.receivedImages = images
                return "A sample diagram showing workflow."
            }
        }

        let mockEngine = MockVisionEngine()
        config.auxiliaryVisionEngine = "ollama"
        config.auxiliaryVisionModel = "llava"

        await AuxiliaryModelManager.$scopedEngines.withValue(["vision": mockEngine]) {
            let result = await VisionRouter.processTextOnlyImages(attachments: [imageAttachment], config: config)
            XCTAssertTrue(result.warnings.isEmpty)
            XCTAssertTrue(result.descriptionText.contains("<image_description file=\"test_image.png\">"))
            XCTAssertTrue(result.descriptionText.contains("A sample diagram showing workflow."))
            XCTAssertTrue(result.descriptionText.contains("</image_description>"))
            XCTAssertEqual(mockEngine.receivedImages, [dummyData.base64EncodedString()])
        }
    }
}
