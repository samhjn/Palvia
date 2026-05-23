import XCTest
@testable import iClaw

final class JSFetchProxyTests: XCTestCase {

    // MARK: - Scheme Constants

    func testSchemeIsIclawJS() {
        XCTAssertEqual(JSFetchSchemeHandler.scheme, "iclaw-js")
    }

    func testSandboxBaseURLScheme() {
        let url = JSFetchSchemeHandler.sandboxBaseURL
        XCTAssertEqual(url.scheme, "iclaw-js")
    }

    func testSandboxBaseURLHost() {
        let url = JSFetchSchemeHandler.sandboxBaseURL
        XCTAssertEqual(url.host, "sandbox")
    }

    func testSandboxBaseURLPath() {
        let url = JSFetchSchemeHandler.sandboxBaseURL
        XCTAssertEqual(url.path, "/")
    }

    func testSandboxBaseURLString() {
        let url = JSFetchSchemeHandler.sandboxBaseURL
        XCTAssertEqual(url.absoluteString, "iclaw-js://sandbox/")
    }

    // MARK: - Proxy URL Resolution

    /// The JS fetch polyfill sends XHR to a relative path `/fetch?url=...`.
    /// When resolved against the sandbox base URL, it must stay same-origin.
    func testProxyURLIsSameOriginAsSandbox() {
        let base = JSFetchSchemeHandler.sandboxBaseURL
        let proxy = URL(string: "/fetch?url=https%3A%2F%2Fexample.com", relativeTo: base)!
        XCTAssertEqual(proxy.scheme, base.scheme)
        XCTAssertEqual(proxy.host, base.host)
    }

    func testProxyURLPreservesEncodedTargetURL() {
        let target = "https://example.com/page?q=hello world"
        let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let proxyPath = "/fetch?url=\(encoded)"
        let base = JSFetchSchemeHandler.sandboxBaseURL
        let proxyURL = URL(string: proxyPath, relativeTo: base)!

        let components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: true)!
        let extractedTarget = components.queryItems?.first(where: { $0.name == "url" })?.value
        XCTAssertEqual(extractedTarget, target)
    }

    // MARK: - Fetch Polyfill Script Validation

    func testFetchPolyfillUsesProxyPath() {
        let script = JavaScriptExecutor.runtimeScript
        XCTAssertTrue(script.contains("/fetch?url="), "Fetch should route through proxy path")
    }

    func testFetchPolyfillEncodesTargetURL() {
        let script = JavaScriptExecutor.runtimeScript
        XCTAssertTrue(script.contains("encodeURIComponent(targetUrl)"),
                       "Fetch should percent-encode the target URL")
    }

    func testFetchPolyfillUsesSameOriginProxy() {
        let script = JavaScriptExecutor.runtimeScript
        // The proxy URL should be relative (starts with /), not absolute,
        // so it resolves against the page's own origin.
        XCTAssertTrue(script.contains("var proxyUrl = '/fetch?url='"),
                       "Proxy URL should be a relative path for same-origin resolution")
    }

    func testFetchPolyfillDoesNotHardcodeExternalOrigin() {
        let script = JavaScriptExecutor.runtimeScript
        XCTAssertFalse(script.contains("https://localhost"),
                        "Fetch must not reference the old https://localhost origin")
    }

    func testFetchPolyfillPreservesSynchronousXHR() {
        let script = JavaScriptExecutor.runtimeScript
        // The third argument to xhr.open() must be false for synchronous operation
        XCTAssertTrue(script.contains("xhr.open(method, proxyUrl, false)"),
                       "XHR must remain synchronous (async=false)")
    }

    func testFetchPolyfillReturnsExpectedShape() {
        let script = JavaScriptExecutor.runtimeScript
        // The return value must contain the standard response fields
        for field in ["ok:", "status:", "text:", "json:", "headers:", "statusText:"] {
            XCTAssertTrue(script.contains(field),
                           "Fetch response object must contain '\(field)' field")
        }
    }

    // MARK: - Handler Instantiation

    func testSchemeHandlerCanBeInstantiated() {
        let handler = JSFetchSchemeHandler()
        XCTAssertNotNil(handler)
    }
}
