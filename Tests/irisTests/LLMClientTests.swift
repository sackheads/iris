import XCTest
@testable import IrisKit

final class LLMClientTests: XCTestCase {
    
    func testResolveGeminiRequestURLAPIKeyModeDefault() throws {
        let url = try LLMClient.resolveGeminiRequestURL(
            modelName: "gemini-3.5-flash",
            isADC: false,
            customBaseURL: "",
            quotaProject: nil
        )
        XCTAssertEqual(url.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent")
    }
    
    func testResolveGeminiRequestURLADCModeDefaultToGlobalVertex() throws {
        let url = try LLMClient.resolveGeminiRequestURL(
            modelName: "gemini-3.5-flash",
            isADC: true,
            customBaseURL: "",
            quotaProject: "gke-bnaylor-hosted-master"
        )
        XCTAssertEqual(url.absoluteString, "https://aiplatform.googleapis.com/v1/projects/gke-bnaylor-hosted-master/locations/global/publishers/google/models/gemini-3.5-flash:generateContent")
    }
    
    func testResolveGeminiRequestURLCustomBaseURLOverridesBoth() throws {
        let custom = "https://custom.proxy.dev/gemini/generate"
        let urlApiKey = try LLMClient.resolveGeminiRequestURL(
            modelName: "gemini-3.5-flash",
            isADC: false,
            customBaseURL: custom,
            quotaProject: nil
        )
        let urlADC = try LLMClient.resolveGeminiRequestURL(
            modelName: "gemini-3.5-flash",
            isADC: true,
            customBaseURL: custom,
            quotaProject: "test-project"
        )
        XCTAssertEqual(urlApiKey.absoluteString, custom)
        XCTAssertEqual(urlADC.absoluteString, custom)
    }
    
    func testResolveGeminiRequestURLADCModeWithoutProjectThrows() {
        XCTAssertThrowsError(try LLMClient.resolveGeminiRequestURL(
            modelName: "gemini-3.5-flash",
            isADC: true,
            customBaseURL: "",
            quotaProject: nil
        )) { error in
            guard let apiError = error as? APIError else {
                XCTFail("Expected APIError, got \(error)")
                return
            }
            XCTAssertTrue(apiError.message.contains("GCP Project ID not found"), "Error message should instruct user to set project: \(apiError.message)")
        }
    }
    
    func testResolveGeminiRequestURLADCModeTrimsWhitespaceInProject() throws {
        let url = try LLMClient.resolveGeminiRequestURL(
            modelName: "gemini-3.5-flash",
            isADC: true,
            customBaseURL: "",
            quotaProject: "  my-test-project \n"
        )
        XCTAssertEqual(url.absoluteString, "https://aiplatform.googleapis.com/v1/projects/my-test-project/locations/global/publishers/google/models/gemini-3.5-flash:generateContent")
    }
    
    func testEndpointForTierReturnsURL() async {
        let client = LLMClient()
        let endpoint = await client.endpoint(for: .medium)
        XCTAssertFalse(endpoint.isEmpty)
    }
}
