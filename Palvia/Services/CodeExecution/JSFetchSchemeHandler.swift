import Foundation
import WebKit
import os.log

private let fetchLog = OSLog(subsystem: "com.iclaw.jsruntime", category: "fetch-proxy")

/// Proxies network requests from the JS sandbox through URLSession,
/// bypassing WKWebView's CORS restrictions on synchronous XMLHttpRequest.
///
/// The JS runtime page is loaded with `baseURL = iclaw-js://sandbox/`.
/// The `fetch` polyfill sends synchronous XHR to the same-origin path
/// `iclaw-js://sandbox/fetch?url=<encoded>`, which this handler intercepts
/// and proxies via URLSession (no CORS enforcement).
///
/// Because JS runs in the WebContent process (separate from the app process),
/// synchronous XHR blocks only the JS thread while the scheme handler
/// completes the real request asynchronously — no deadlock risk.
final class JSFetchSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "iclaw-js"

    /// Base URL used as the WKWebView page origin.
    static var sandboxBaseURL: URL {
        URL(string: "\(scheme)://sandbox/")!
    }

    // MARK: - Active task tracking

    /// Active URLSession tasks keyed by WKURLSchemeTask identity,
    /// used to cancel in-flight requests when WebKit calls `stop`.
    private var activeTasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private let lock = NSLock()

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              components.path == "/fetch",
              let targetURLString = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let targetURL = URL(string: targetURLString) else {
            // Not a fetch proxy request — return 404
            let response = HTTPURLResponse(
                url: urlSchemeTask.request.url ?? URL(string: "about:blank")!,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didFinish()
            return
        }

        // Build the real outbound request
        var request = URLRequest(url: targetURL)
        request.httpMethod = urlSchemeTask.request.httpMethod ?? "GET"
        request.httpBody = urlSchemeTask.request.httpBody
        request.timeoutInterval = 30

        // Forward headers from the XHR, skipping internal/origin headers
        let skipHeaders: Set<String> = ["host", "origin", "referer"]
        if let headers = urlSchemeTask.request.allHTTPHeaderFields {
            for (key, value) in headers where !skipHeaders.contains(key.lowercased()) {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        // Set a browser-like User-Agent so sites don't reject the request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
        }

        os_log(.info, log: fetchLog, "[FetchProxy] %{public}@ %{public}@", request.httpMethod ?? "GET", targetURLString)

        let taskKey = ObjectIdentifier(urlSchemeTask as AnyObject)

        let dataTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            // Remove from tracking; if already removed, the task was stopped — bail out.
            self.lock.lock()
            let removed = self.activeTasks.removeValue(forKey: taskKey)
            self.lock.unlock()
            guard removed != nil else { return }

            DispatchQueue.main.async {
                if let error {
                    os_log(.error, log: fetchLog, "[FetchProxy] error: %{public}@", error.localizedDescription)
                    urlSchemeTask.didFailWithError(error)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    urlSchemeTask.didFailWithError(URLError(.badServerResponse))
                    return
                }

                // Convert response headers from [AnyHashable: Any] to [String: String]
                var headerFields: [String: String] = [:]
                for (key, value) in httpResponse.allHeaderFields {
                    headerFields[String(describing: key)] = String(describing: value)
                }

                let proxyResponse = HTTPURLResponse(
                    url: requestURL,
                    statusCode: httpResponse.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: headerFields
                )!

                urlSchemeTask.didReceive(proxyResponse)
                if let data {
                    urlSchemeTask.didReceive(data)
                }
                urlSchemeTask.didFinish()

                os_log(.info, log: fetchLog, "[FetchProxy] completed %d, %d bytes",
                       httpResponse.statusCode, data?.count ?? 0)
            }
        }

        lock.lock()
        activeTasks[taskKey] = dataTask
        lock.unlock()

        dataTask.resume()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let taskKey = ObjectIdentifier(urlSchemeTask as AnyObject)
        lock.lock()
        let task = activeTasks.removeValue(forKey: taskKey)
        lock.unlock()
        task?.cancel()
        os_log(.info, log: fetchLog, "[FetchProxy] stopped/cancelled task")
    }
}
