import XCTest
@testable import IrisKit

final class OllamaEngineTests: XCTestCase {
    
    // MARK: - parseModelNames (from /api/tags)
    
    func testParseModelNamesFromTagsResponse() {
        let json = """
        {
            "models": [
                {"name": "gemma4:12b", "size": 7556508396},
                {"name": "qwen3.5:latest", "size": 5432109876},
                {"name": "llama3.2:3b", "size": 2012345678}
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let names = OllamaEngine.parseModelNames(from: data)
        XCTAssertEqual(names, ["gemma4:12b", "llama3.2:3b", "qwen3.5:latest"])
    }
    
    func testParseModelNamesEmptyResponse() {
        let json = #"{"models": []}"#
        let data = json.data(using: .utf8)!
        let names = OllamaEngine.parseModelNames(from: data)
        XCTAssertTrue(names.isEmpty)
    }
    
    func testParseModelNamesMissingKey() {
        let json = #"{"other": "value"}"#
        let data = json.data(using: .utf8)!
        let names = OllamaEngine.parseModelNames(from: data)
        XCTAssertTrue(names.isEmpty)
    }
    
    func testParseModelNamesInvalidJSON() {
        let json = "{ not json }"
        let data = json.data(using: .utf8)!
        let names = OllamaEngine.parseModelNames(from: data)
        XCTAssertTrue(names.isEmpty)
    }
    
    // MARK: - parsePullStatus (from /api/pull)
    
    func testParsePullStatusSuccess() {
        let json = #"{"status": "success"}"#
        let data = json.data(using: .utf8)!
        let status = OllamaEngine.parsePullStatus(from: data)
        XCTAssertEqual(status, "success")
    }
    
    func testParsePullStatusProgress() {
        let json = #"{"status": "downloading 45%"}"#
        let data = json.data(using: .utf8)!
        let status = OllamaEngine.parsePullStatus(from: data)
        XCTAssertEqual(status, "downloading 45%")
    }
    
    func testParsePullStatusInvalidJSON() {
        let json = "{ broken }"
        let data = json.data(using: .utf8)!
        let status = OllamaEngine.parsePullStatus(from: data)
        XCTAssertNil(status)
    }
    
    // MARK: - parsePSModels + modelIsInPSList (from /api/ps)
    
    func testParsePSModelsAndModelFound() {
        let json = """
        {
            "models": [
                {"name": "gemma4:12b", "size": 7556508396},
                {"name": "qwen3.5:latest", "size": 5432109876}
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let models = OllamaEngine.parsePSModels(from: data)
        XCTAssertEqual(models.count, 2)
        XCTAssertTrue(OllamaEngine.modelIsInPSList("gemma4:12b", models: models))
    }
    
    func testParsePSModelsModelNotFound() {
        let json = #"{"models": [{"name": "qwen3.5:latest"}]}"#
        let data = json.data(using: .utf8)!
        let models = OllamaEngine.parsePSModels(from: data)
        XCTAssertFalse(OllamaEngine.modelIsInPSList("gemma4:12b", models: models))
    }
    
    func testModelIsInPSListColonPrefixMatch() {
        // Ollama tag separator is ":" — "gemma4:12b" should match "gemma4:12b:text"
        let models: [[String: Any]] = [["name": "gemma4:12b:text"]]
        XCTAssertTrue(OllamaEngine.modelIsInPSList("gemma4:12b", models: models))
        
        // Dash suffix should NOT match
        let dashModels: [[String: Any]] = [["name": "gemma4:12b-Q4_K_M"]]
        XCTAssertFalse(OllamaEngine.modelIsInPSList("gemma4:12b", models: dashModels))
    }
    
    func testParsePSModelsInvalidJSON() {
        let json = "{ bad }"
        let data = json.data(using: .utf8)!
        let models = OllamaEngine.parsePSModels(from: data)
        XCTAssertTrue(models.isEmpty)
    }
    
    // MARK: - URL construction
    
    func testBaseURLEndpointConstruction() {
        let base = "http://localhost:11434"
        XCTAssertEqual(URL(string: "\(base)/api/tags")?.absoluteString, "http://localhost:11434/api/tags")
        XCTAssertEqual(URL(string: "\(base)/api/generate")?.absoluteString, "http://localhost:11434/api/generate")
        XCTAssertEqual(URL(string: "\(base)/api/pull")?.absoluteString, "http://localhost:11434/api/pull")
        XCTAssertEqual(URL(string: "\(base)/api/ps")?.absoluteString, "http://localhost:11434/api/ps")
    }
}
