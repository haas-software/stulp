import Foundation
import Testing
@testable import StulpKit

@Suite("Verbinding")
struct ConnectionTests {
    @Test func addressAndKey() throws {
        let c = try StulpConnection.parse(address: "https://stulp.example.org", key: "  geheim ")
        #expect(c.baseURL.absoluteString == "https://stulp.example.org")
        #expect(c.accessKey == "geheim")
        #expect(c.authorization == "Bearer geheim")
    }

    @Test func bareHostBecomesHTTPS() throws {
        let c = try StulpConnection.parse(address: "stulp.local:8080", key: "k")
        #expect(c.baseURL.absoluteString == "https://stulp.local:8080")
        #expect(c.displayAddress == "stulp.local:8080")
    }

    @Test func plainHTTPOnTheLANStaysHTTP() throws {
        let c = try StulpConnection.parse(address: "http://192.168.1.20:8080/", key: "k")
        #expect(c.baseURL.absoluteString == "http://192.168.1.20:8080")
    }

    /// People still have the old Manage link; it carries the key in its path.
    @Test func oldManageLinkCarriesTheKey() throws {
        let c = try StulpConnection.parse(address: "https://demo.gethop.org/EEN-LANGE-SLEUTEL")
        #expect(c.baseURL.absoluteString == "https://demo.gethop.org")
        #expect(c.accessKey == "EEN-LANGE-SLEUTEL")
        #expect(try StulpConnection.parse("https://demo.gethop.org/abc").accessKey == "abc")
    }

    @Test func typedKeyWinsOverTheLink() throws {
        let c = try StulpConnection.parse(address: "https://demo.gethop.org/oud", key: "nieuw")
        #expect(c.accessKey == "nieuw")
        #expect(c.baseURL.absoluteString == "https://demo.gethop.org")
    }

    @Test(arguments: [
        ("", "k", StulpConnectionError.empty),
        ("   ", "k", .empty),
        ("https://stulp.local", "", .missingKey),
        ("ftp://stulp.local", "k", .invalidURL),
        ("https://stulp.local?x=1", "k", .invalidURL),
        ("https://user:pw@stulp.local", "k", .invalidURL),
        ("https://stulp.local/a/b", "", .invalidURL),
    ])
    func refuses(_ address: String, _ key: String, _ expected: StulpConnectionError) {
        #expect(throws: expected) { try StulpConnection.parse(address: address, key: key) }
    }

    /// `printf 'stulp web session\0dev' | shasum -a 256`, the proof the server derives.
    @Test func appUISessionProof() {
        let c = StulpConnection(baseURL: URL(string: "http://127.0.0.1:8080")!, accessKey: "dev")
        #expect(c.appUISessionProof == "a807e83631a672bd48694186efec2d941ef4eaddf7aa7d9e5a8f3ad5caf585d3")
    }

    @Test func roundTripsThroughCodable() throws {
        let c = try StulpConnection.parse(address: "stulp.local", key: "k")
        let back = try JSONDecoder().decode(StulpConnection.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }
}
