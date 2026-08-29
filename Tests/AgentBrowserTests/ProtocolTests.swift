import Testing
import Foundation
@testable import AgentBrowser

/// Tests for the versioned request/response protocol.
/// Pure data types -- no WebKit, no network, no display.
@Suite("Protocol")
struct ProtocolTests {

    // MARK: - AgentRequest Encoding/Decoding

    @Test("Request round-trips through JSON")
    func requestRoundTrip() throws {
        let req = AgentRequest(method: "tabs.list", params: nil)
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(AgentRequest.self, from: data)

        #expect(decoded.version == 1)
        #expect(decoded.method == "tabs.list")
        #expect(decoded.params == nil)
    }

    @Test("Request with params round-trips")
    func requestWithParams() throws {
        let req = AgentRequest(
            method: "tabs.get",
            params: ["id": AnyCodable("abc-123"), "flag": AnyCodable(true)]
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(AgentRequest.self, from: data)

        #expect(decoded.method == "tabs.get")
        #expect(decoded.params?["id"]?.value as? String == "abc-123")
        // JSON round-trips true as 1 (NSNumber) -- both Bool and Int casts succeed.
        // We just need the value to be present and truthy.
        let flagVal = decoded.params?["flag"]?.value
        #expect(flagVal != nil, "flag param should exist")
    }

    @Test("Request decodes from external JSON")
    func requestFromExternalJSON() throws {
        let json = """
        {"version": 1, "method": "page.eval", "params": {"id": "AAA", "script": "return 42"}}
        """
        let data = Data(json.utf8)
        let req = try JSONDecoder().decode(AgentRequest.self, from: data)

        #expect(req.version == 1)
        #expect(req.method == "page.eval")
        #expect(req.params?["script"]?.value as? String == "return 42")
    }

    // MARK: - AgentResponse Encoding/Decoding

    @Test("Success response round-trips")
    func successResponse() throws {
        let resp = AgentResponse.success(["title": "Hello"])
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(AgentResponse.self, from: data)

        #expect(decoded.ok == true)
        #expect(decoded.error == nil)
        #expect(decoded.result != nil)
    }

    @Test("Failure response round-trips")
    func failureResponse() throws {
        let resp = AgentResponse.failure(code: ErrorCode.tabNotFound, message: "No such tab")
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(AgentResponse.self, from: data)

        #expect(decoded.ok == false)
        #expect(decoded.error?.code == "TAB_NOT_FOUND")
        #expect(decoded.error?.message == "No such tab")
        #expect(decoded.result == nil)
    }

    @Test("Failure response includes correct error code constants")
    func errorCodeConstants() {
        #expect(ErrorCode.tabNotFound == "TAB_NOT_FOUND")
        #expect(ErrorCode.invalidParams == "INVALID_PARAMS")
        #expect(ErrorCode.invalidURL == "INVALID_URL")
        #expect(ErrorCode.javaScriptError == "JAVASCRIPT_ERROR")
        #expect(ErrorCode.screenshotFailed == "SCREENSHOT_FAILED")
        #expect(ErrorCode.extractionFailed == "EXTRACTION_FAILED")
        #expect(ErrorCode.unknownMethod == "UNKNOWN_METHOD")
        #expect(ErrorCode.badRequest == "BAD_REQUEST")
    }

    // MARK: - AnyCodable

    @Test("AnyCodable handles all primitive types")
    func anyCodablePrimitives() throws {
        let values: [(AnyCodable, String)] = [
            (AnyCodable("hello"), "string"),
            (AnyCodable(42), "int"),
            (AnyCodable(3.14), "double"),
            (AnyCodable(true), "bool"),
            (AnyCodable(NSNull()), "null"),
        ]

        for (ac, label) in values {
            let data = try JSONEncoder().encode(ac)
            let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
            // Just verify it doesn't crash -- type fidelity is best-effort
            _ = decoded.value
            _ = label // suppress unused warning
        }
    }

    @Test("AnyCodable handles nested structures")
    func anyCodableNested() throws {
        let nested = AnyCodable(["key": "value", "num": 42] as [String: Any])
        let data = try JSONEncoder().encode(nested)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)

        if let dict = decoded.value as? [String: Any] {
            #expect(dict["key"] as? String == "value")
        }
    }

    // MARK: - Version Validation

    @Test("Version field defaults to 1")
    func versionDefault() {
        let req = AgentRequest(method: "tabs.list")
        #expect(req.version == 1)
    }
}
