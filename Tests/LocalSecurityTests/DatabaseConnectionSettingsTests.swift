import Foundation
import XCTest

@testable import LocalSecurity

final class DatabaseConnectionSettingsTests: XCTestCase {
    private func url(scheme: String = "postgresql", mode: String? = nil) -> String {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "database.example.com"
        parts.user = "test-user"
        parts.password = "synthetic value with @ and :"
        parts.path = "/test_catalog"
        if let mode { parts.queryItems = [URLQueryItem(name: "sslmode", value: mode)] }
        return parts.string!
    }

    func testAcceptsPostgresSchemesAndDecodesCredentials() throws {
        for scheme in ["postgres", "postgresql"] {
            let value = try DatabaseConnectionSettings(urlString: url(scheme: scheme))
            XCTAssertEqual(value.host, "database.example.com")
            XCTAssertEqual(value.port, 5432)
            XCTAssertEqual(value.database, "test_catalog")
            XCTAssertEqual(value.password, "synthetic value with @ and :")
        }
    }

    func testAllowsOnlyTLSRequiredModes() throws {
        for mode in ["require", "verify-full"] {
            XCTAssertNoThrow(try DatabaseConnectionSettings(urlString: url(mode: mode)))
        }
        for mode in ["disable", "allow", "prefer", "verify-ca", "unknown", ""] {
            XCTAssertThrowsError(try DatabaseConnectionSettings(urlString: url(mode: mode)))
        }
    }

    func testRejectsMissingFieldsWrongSchemesFragmentsAndDuplicateModes() {
        for value in [
            "", "https://example.com", url(scheme: "https"), url() + "#fragment",
            url(mode: "require") + "&sslmode=disable",
        ] {
            XCTAssertThrowsError(try DatabaseConnectionSettings(urlString: value))
        }
    }

    func testValidationErrorsDoNotContainCredentialsOrHost() {
        do {
            _ = try DatabaseConnectionSettings(urlString: url(mode: "disable"))
            XCTFail("An insecure mode was accepted")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("test-user"))
            XCTAssertFalse(error.localizedDescription.contains("synthetic"))
            XCTAssertFalse(error.localizedDescription.contains("database.example.com"))
        }
    }

    func testCustomRootCertificateIsScopedToTheConnectionAndDuplicateOptionsFail() throws {
        let value = try DatabaseConnectionSettings(
            urlString: url() + "?sslrootcert=%2Ftmp%2Fstreamvibes-fixture-ca.crt")
        XCTAssertEqual(value.sslRootCertificate, "/tmp/streamvibes-fixture-ca.crt")
        XCTAssertNil(try DatabaseConnectionSettings(urlString: url()).sslRootCertificate)
        XCTAssertThrowsError(try DatabaseConnectionSettings(urlString: url() + "?sslrootcert="))
        XCTAssertThrowsError(try DatabaseConnectionSettings(urlString: url() + "?sslrootcert=a&sslrootcert=b"))
    }
}
