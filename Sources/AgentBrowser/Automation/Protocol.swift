import Foundation

/// Versioned request/response protocol for agent communication.
/// Boring by design. No JSON-RPC -- just versioning, methods, params, results, typed errors.

// MARK: - Request

struct AgentRequest: Codable, Sendable {
    let version: Int
    let method: String
    let params: [String: AnyCodable]?

    init(method: String, params: [String: AnyCodable]? = nil) {
        self.version = 1
        self.method = method
        self.params = params
    }
}

// MARK: - Response

struct AgentResponse: Codable, Sendable {
    let ok: Bool
    let result: AnyCodable?
    let error: AgentErrorDetail?

    static func success(_ value: some Encodable & Sendable) -> AgentResponse {
        AgentResponse(ok: true, result: AnyCodable(value), error: nil)
    }

    static func failure(code: String, message: String) -> AgentResponse {
        AgentResponse(ok: false, result: nil, error: AgentErrorDetail(code: code, message: message))
    }
}

struct AgentErrorDetail: Codable, Sendable {
    let code: String
    let message: String
}

// MARK: - Error Codes (constants)

enum ErrorCode {
    static let tabNotFound = "TAB_NOT_FOUND"
    static let invalidParams = "INVALID_PARAMS"
    static let invalidURL = "INVALID_URL"
    static let javaScriptError = "JAVASCRIPT_ERROR"
    static let screenshotFailed = "SCREENSHOT_FAILED"
    static let pageNotReady = "PAGE_NOT_READY"
    static let extractionFailed = "EXTRACTION_FAILED"
    static let unknownMethod = "UNKNOWN_METHOD"
    static let badRequest = "BAD_REQUEST"
    static let elementNotFound = "ELEMENT_NOT_FOUND"
    static let elementStale = "ELEMENT_STALE"
    static let elementNotInteractable = "ELEMENT_NOT_INTERACTABLE"
    static let unsupportedElement = "UNSUPPORTED_ELEMENT"
    static let waitTimeout = "WAIT_TIMEOUT"
    static let navigationFailed = "NAVIGATION_FAILED"
    static let invalidArgument = "INVALID_ARGUMENT"
}

// MARK: - AnyCodable (lightweight type-erased Codable)

/// Minimal type-erased Codable for protocol params and results.
/// Supports: String, Int, Double, Bool, nil, [AnyCodable], [String: AnyCodable].
struct AnyCodable: Codable, @unchecked Sendable {
    // @unchecked because `value` is `Any` but we only store Foundation primitives
    // (String, Int, Double, Bool, NSNull, Array, Dictionary) which are all value types.
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(_ value: some Encodable & Sendable) {
        // Encode then decode through JSON to get a clean Any representation
        if let data = try? JSONEncoder().encode(value),
           let json = try? JSONSerialization.jsonObject(with: data) {
            self.value = json
        } else {
            self.value = String(describing: value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encode(String(describing: value))
        }
    }
}
