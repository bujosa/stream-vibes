import XCTest
@testable import LocalSecurity

final class MetadataRequestTests: XCTestCase {
    func testMissingCredentialSkipsOMDb() {
        XCTAssertNil(MetadataRequest.omdbURL(apiKey: " \n", parameters: []))
    }

    func testTitleAndCredentialCannotInjectQueryParameters() throws {
        let title = "Movie + sequel &apikey=other#fragment"
        let credential = "example + value&part"
        let url = try XCTUnwrap(MetadataRequest.omdbURL(
            apiKey: credential,
            parameters: [URLQueryItem(name: "t", value: title), URLQueryItem(name: "Season", value: "2")]
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.omdbapi.com")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "t" })?.value, title)
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "apikey" })?.value, credential)
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "Season" })?.value, "2")
        XCTAssertNil(components.fragment)
        XCTAssertFalse(url.absoluteString.contains("+"))
    }

    func testOnlyConfiguredCredentialIsIncluded() throws {
        let url = try XCTUnwrap(MetadataRequest.omdbURL(
            apiKey: "example credential",
            parameters: [URLQueryItem(name: "apikey", value: "discarded example")]
        ))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name == "apikey" }.count, 1)
        XCTAssertEqual(items.first?.value, "example credential")
    }
}
