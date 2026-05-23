import Foundation

/// Shared utilities for building API requests across all services.
enum APIRequestBuilder {

    /// JSONEncoder configured with `.sortedKeys` so request bodies are
    /// byte-identical across runs. Required for prompt-caching providers
    /// (Anthropic, DeepSeek, etc.): Swift `Dictionary` iteration order is
    /// non-deterministic, so dict-backed fields like `JSONSchema.properties`
    /// and Anthropic `tool_use.input` would otherwise scramble between
    /// requests and defeat the cache.
    static let stableJSONEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    // MARK: - URL Construction

    /// Join a base URL with a path, normalizing trailing slashes.
    static func buildURL(base: String, path: String) throws -> URL {
        let normalizedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let urlString = normalizedBase + normalizedPath
        guard let url = URL(string: urlString) else {
            throw APIRequestError.invalidURL(urlString)
        }
        return url
    }

    // MARK: - Common Headers

    /// Apply common iClaw headers (User-Agent, Referer, Title).
    static func applyCommonHeaders(to request: inout URLRequest) {
        request.addValue("iClaw/1.0 (https://iclaw.shadow.mov)", forHTTPHeaderField: "User-Agent")
        request.addValue("https://iclaw.shadow.mov", forHTTPHeaderField: "HTTP-Referer")
        request.addValue("iClaw", forHTTPHeaderField: "X-Title")
    }

    /// Apply authentication headers based on API style.
    static func applyAuth(to request: inout URLRequest, apiKey: String, style: APIStyle) {
        guard !apiKey.isEmpty else { return }
        switch style {
        case .anthropic:
            request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI, .openAIResponses, .googleVeo, .dashScope, .kling, .seedance:
            // All non-Anthropic protocols use Bearer token auth
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Apply Bearer token authentication.
    static func applyBearerAuth(to request: inout URLRequest, apiKey: String) {
        guard !apiKey.isEmpty else { return }
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    /// Apply Google API key authentication.
    static func applyGoogleAuth(to request: inout URLRequest, apiKey: String) {
        guard !apiKey.isEmpty else { return }
        request.addValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    }

    // MARK: - Request Building

    /// Build a JSON POST request with common headers and auth.
    static func jsonPOST(
        base: String,
        path: String,
        apiKey: String,
        style: APIStyle,
        body: Data
    ) throws -> URLRequest {
        let url = try buildURL(base: base, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(to: &request)
        applyAuth(to: &request, apiKey: apiKey, style: style)
        request.httpBody = body
        return request
    }

    /// Build a GET request with common headers and auth.
    static func jsonGET(
        base: String,
        path: String,
        apiKey: String,
        style: APIStyle
    ) throws -> URLRequest {
        let url = try buildURL(base: base, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request)
        applyAuth(to: &request, apiKey: apiKey, style: style)
        return request
    }

    // MARK: - Response Validation

    /// Validate an HTTP response, throwing on non-2xx status codes.
    @discardableResult
    static func validate(data: Data, response: URLResponse) throws -> Data {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIRequestError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIRequestError.httpError(statusCode: httpResponse.statusCode, message: body)
        }
        return data
    }
}

// MARK: - Error Type

enum APIRequestError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code, let msg):
            return "API Error (\(code)): \(msg)"
        }
    }

    /// The HTTP status code, if this is an HTTP error.
    var statusCode: Int? {
        if case .httpError(let code, _) = self { return code }
        return nil
    }

    /// The error message body, if this is an HTTP error.
    var messageBody: String? {
        if case .httpError(_, let msg) = self { return msg }
        return nil
    }
}
