import XCTest
@testable import IrisKit

final class GCloudHelperTests: XCTestCase {
    
    // MARK: - requiredAPIs
    
    func testRequiredAPIsCount() {
        XCTAssertEqual(GCloudHelper.requiredAPIs.count, 9, "Nine APIs should be defined (6 Workspace + 3 Google Cloud AI APIs)")
    }
    
    func testRequiredAPIsUniqueIDs() {
        let ids = GCloudHelper.requiredAPIs.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "API service names must be unique")
    }
    
    func testRequiredAPIIDsAreCorrect() {
        let ids = Set(GCloudHelper.requiredAPIs.map(\.id))
        XCTAssertTrue(ids.contains("calendar-json.googleapis.com"))
        XCTAssertTrue(ids.contains("drive.googleapis.com"))
        XCTAssertTrue(ids.contains("docs.googleapis.com"))
        XCTAssertTrue(ids.contains("sheets.googleapis.com"))
        XCTAssertTrue(ids.contains("gmail.googleapis.com"))
        XCTAssertTrue(ids.contains("tasks.googleapis.com"))
        XCTAssertTrue(ids.contains("aiplatform.googleapis.com"))
        XCTAssertTrue(ids.contains("cloudaicompanion.googleapis.com"))
        XCTAssertTrue(ids.contains("generativelanguage.googleapis.com"))
        XCTAssertFalse(ids.contains("people.googleapis.com"))
    }
    
    func testRequiredAPIScopesAreCorrect() {
        let scopes = Set(GCloudHelper.requiredAPIs.map(\.scope))
        XCTAssertTrue(scopes.contains("https://www.googleapis.com/auth/calendar"))
        XCTAssertTrue(scopes.contains("https://www.googleapis.com/auth/drive"))
        XCTAssertTrue(scopes.contains("https://www.googleapis.com/auth/documents"))
        XCTAssertTrue(scopes.contains("https://www.googleapis.com/auth/spreadsheets"))
        XCTAssertTrue(scopes.contains("https://www.googleapis.com/auth/gmail.modify"))
        XCTAssertTrue(scopes.contains("https://www.googleapis.com/auth/tasks"))
        XCTAssertTrue(scopes.contains("https://www.googleapis.com/auth/cloud-platform"))
        XCTAssertTrue(scopes.contains("https://www.googleapis.com/auth/generative-language"))
        XCTAssertFalse(scopes.contains("https://www.googleapis.com/auth/userinfo.email"))
    }
    
    func testRequiredAPIDisplayNames() {
        let names = GCloudHelper.requiredAPIs.map(\.displayName)
        XCTAssertTrue(names.contains("Google Calendar"))
        XCTAssertTrue(names.contains("Google Drive"))
        XCTAssertTrue(names.contains("Google Docs"))
        XCTAssertTrue(names.contains("Google Sheets"))
        XCTAssertTrue(names.contains("Gmail"))
        XCTAssertTrue(names.contains("Google Tasks"))
        XCTAssertTrue(names.contains("Vertex AI"))
        XCTAssertTrue(names.contains("Cloud AI Companion"))
        XCTAssertTrue(names.contains("Gemini API"))
        XCTAssertFalse(names.contains("Google People"))
    }
    
    func testAPIInfoIdentifiable() {
        let api = GCloudHelper.requiredAPIs[0]
        XCTAssertEqual(api.id, api.id as String)
    }
    
    func testAPIInfoDefaultEnabledIsFalse() {
        for api in GCloudHelper.requiredAPIs {
            XCTAssertFalse(api.enabled, "\(api.displayName) should default to enabled=false")
        }
    }
    
    // MARK: - parseEnabledServices (pure function)
    
    func testParseEnabledServicesNormalOutput() {
        let output = """
        calendar-json.googleapis.com
        drive.googleapis.com
        docs.googleapis.com
        """
        let services = GCloudHelper.parseEnabledServices(from: output)
        XCTAssertEqual(services.count, 3)
        XCTAssertTrue(services.contains("calendar-json.googleapis.com"))
        XCTAssertTrue(services.contains("drive.googleapis.com"))
        XCTAssertTrue(services.contains("docs.googleapis.com"))
        XCTAssertFalse(services.contains("sheets.googleapis.com"))
    }
    
    func testParseEnabledServicesEmptyOutput() {
        let services = GCloudHelper.parseEnabledServices(from: "")
        XCTAssertTrue(services.isEmpty)
    }
    
    func testParseEnabledServicesFiltersBlankLines() {
        let output = """
        calendar-json.googleapis.com
        
        drive.googleapis.com
        
        """
        let services = GCloudHelper.parseEnabledServices(from: output)
        XCTAssertEqual(services.count, 2)
    }
    
    // MARK: - APIInfo mutation
    
    func testAPIInfoEnabledToggle() {
        var api = GCloudHelper.APIInfo(
            id: "calendar-json.googleapis.com",
            displayName: "Google Calendar",
            scope: "https://www.googleapis.com/auth/calendar",
            enabled: false
        )
        XCTAssertFalse(api.enabled)
        api.enabled = true
        XCTAssertTrue(api.enabled)
    }
    
    func testRequiredAPIsAllEnabledCheck() {
        var apis = GCloudHelper.requiredAPIs.map { api in
            var copy = api
            copy.enabled = true
            return copy
        }
        XCTAssertTrue(apis.allSatisfy(\.enabled))
        
        apis[0].enabled = false
        XCTAssertFalse(apis.allSatisfy(\.enabled))
    }
    
    // MARK: - Binary search paths
    
    func testGCloudSearchPathsNotEmpty() {
        XCTAssertFalse(GCloudHelper.gcloudSearchPaths.isEmpty)
    }
    
    func testGCloudSearchPathsIncludeHomebrew() {
        XCTAssertTrue(GCloudHelper.gcloudSearchPaths.contains("/opt/homebrew/bin/gcloud"))
        XCTAssertTrue(GCloudHelper.gcloudSearchPaths.contains("/usr/local/bin/gcloud"))
    }
    
    func testGCloudSearchPathsContainAbsolutePaths() {
        for path in GCloudHelper.gcloudSearchPaths {
            XCTAssertTrue(path.hasPrefix("/"), "Search path should be absolute: \(path)")
        }
    }
}
