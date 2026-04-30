import SwiftUI
import WebKit

struct BrowserView: View {
    @State private var urlText: String = ""
    @State private var isEditing: Bool = false
    @State private var showTakeOverConfirm: Bool = false
    @State private var showClosePageConfirm: Bool = false
    @Bindable private var browser = BrowserService.shared

    private var isLocked: Bool { browser.isAgentControlled }
    private var hasPage: Bool { browser.currentURL != nil && browser.currentURL?.absoluteString != "about:blank" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLocked {
                    agentControlBanner
                }
                addressBar
                progressBar
                ZStack {
                    WebViewRepresentable(webView: browser.webView)
                        .allowsHitTesting(!isLocked)
                        .overlay {
                            if isLocked {
                                Color.black.opacity(0.04)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                .ignoresSafeArea(edges: .bottom)
                toolbar
            }
            .navigationTitle(L10n.Browser.title)
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                if isLocked {
                    browser.dismissKeyboard()
                }
            }
            .alert(L10n.Browser.takeOverTitle, isPresented: $showTakeOverConfirm) {
                Button(L10n.Browser.takeOver, role: .destructive) {
                    browser.forceReleaseLock()
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Browser.takeOverMessage(browser.lockedByAgentName ?? L10n.Common.unknown))
            }
            .alert(L10n.Browser.closePageTitle, isPresented: $showClosePageConfirm) {
                Button(L10n.Browser.closePage, role: .destructive) {
                    browser.closeAllPages()
                    urlText = ""
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Browser.closePageMessage)
            }
        }
    }

    // MARK: - Agent Control Banner

    @ViewBuilder
    private var agentControlBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.caption)
                .foregroundStyle(.white)

            Text(L10n.Browser.agentControlling(browser.lockedByAgentName ?? L10n.Common.unknown))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                showTakeOverConfirm = true
            } label: {
                Text(L10n.Browser.takeOver)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.25))
                    .clipShape(Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.gradient)
    }

    // MARK: - Address Bar

    private var isLocalFile: Bool { browser.currentAgentScope != nil }

    /// For local Agent files, show a short friendly path instead of the raw
    /// `file://` URL (e.g. "index.html" or "pages/about.html").
    private func displayURL(for url: URL) -> String {
        if let scope = browser.currentAgentScope, url.isFileURL {
            let scopePath = scope.path.hasSuffix("/") ? scope.path : scope.path + "/"
            let full = url.standardizedFileURL.path
            if full.hasPrefix(scopePath) {
                return String(full.dropFirst(scopePath.count))
            }
        }
        return url.absoluteString
    }

    @ViewBuilder
    private var addressBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if browser.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: isLocalFile ? "doc" : "globe")
                        .font(.caption)
                        .foregroundStyle(isLocalFile ? .orange : .secondary)
                }

                TextField(L10n.Browser.urlPlaceholder, text: $urlText, onEditingChanged: { editing in
                    isEditing = editing
                    if editing && !urlText.isEmpty {
                        urlText = browser.currentURL?.absoluteString ?? urlText
                    }
                })
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.system(.subheadline, design: .monospaced))
                .submitLabel(.go)
                .onSubmit {
                    navigateTo(urlText)
                }
                .disabled(isLocked)

                if !urlText.isEmpty && isEditing {
                    Button {
                        urlText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onChange(of: browser.currentURL) { _, newURL in
            if !isEditing, let url = newURL {
                urlText = displayURL(for: url)
            }
        }
    }

    // MARK: - Progress Bar

    @ViewBuilder
    private var progressBar: some View {
        if browser.isLoading {
            ProgressView(value: browser.estimatedProgress)
                .tint(isLocked ? .orange : .blue)
                .scaleEffect(x: 1, y: 0.5)
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 0) {
            toolButton(icon: "chevron.left", enabled: browser.canGoBack && !isLocked) {
                Task { let _ = await browser.goBack() }
            }

            toolButton(icon: "chevron.right", enabled: browser.canGoForward && !isLocked) {
                Task { let _ = await browser.goForward() }
            }

            Spacer()

            if let title = browser.pageTitle, !title.isEmpty {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 200)
            }

            Spacer()

            toolButton(icon: browser.isLoading ? "xmark" : "arrow.clockwise", enabled: !isLocked) {
                if browser.isLoading {
                    browser.webView.stopLoading()
                } else {
                    Task { let _ = await browser.reload() }
                }
            }

            toolButton(icon: "square.and.arrow.up", enabled: browser.currentURL != nil) {
                guard let url = browser.currentURL else { return }
                let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = scene.windows.first?.rootViewController {
                    var topVC = root
                    while let presented = topVC.presentedViewController { topVC = presented }
                    if let popover = av.popoverPresentationController {
                        popover.sourceView = topVC.view
                        popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
                        popover.permittedArrowDirections = []
                    }
                    topVC.present(av, animated: true)
                }
            }

            toolButton(icon: "xmark.square", enabled: hasPage && !isLocked) {
                showClosePageConfirm = true
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func toolButton(icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .frame(width: 44, height: 36)
        }
        .disabled(!enabled)
        .foregroundStyle(enabled ? .blue : .gray.opacity(0.4))
    }

    // MARK: - Navigation

    private func navigateTo(_ input: String) {
        guard !isLocked else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let urlString: String
        if trimmed.contains(".") && !trimmed.contains(" ") {
            urlString = trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"
        } else {
            urlString = "https://www.google.com/search?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed)"
        }

        Task {
            let _ = await browser.navigate(to: urlString)
        }
    }
}

// MARK: - WKWebView UIViewRepresentable

struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        // Prevent the web view's internal scroll view from feeding back into
        // UIKit's safe-area-inset layout cycle, which can block the main thread
        // long enough to trigger the 0x8BADF00D watchdog.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
