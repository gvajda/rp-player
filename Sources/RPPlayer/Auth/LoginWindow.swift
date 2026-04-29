import AppKit
import WebKit

@MainActor
final class LoginWindowController: NSWindowController {
    private static let loginURL = URL(string: "https://radioparadise.com/account/sign-in")!
    private static let windowFrame = NSRect(x: 0, y: 0, width: 500, height: 620)

    private let webView: WKWebView
    private let keychainAuth: any KeychainAuth

    init(keychainAuth: any KeychainAuth) {
        self.keychainAuth = keychainAuth
        let webView = WKWebView(frame: Self.windowFrame, configuration: WKWebViewConfiguration())
        self.webView = webView

        let window = NSWindow(
            contentRect: Self.windowFrame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Radio Paradise"
        window.contentView = webView
        window.center()

        super.init(window: window)
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(keychainAuth:)") }

    func show() {
        showWindow(nil)
        webView.load(URLRequest(url: Self.loginURL))
    }

    /// Extracts the RP session cookie string from a set of `HTTPCookie` values.
    /// Returns `nil` when the three required cookies (`C_username`, `C_passwd`,
    /// `C_validated`) are absent or when the username is `"anonymous"` (not logged in).
    nonisolated static func rpCookieString(from cookies: [HTTPCookie]) -> String? {
        let relevant = cookies.filter {
            $0.domain.hasSuffix("radioparadise.com") &&
            ["C_username", "C_passwd", "C_validated"].contains($0.name)
        }
        guard relevant.count == 3,
              let userCookie = relevant.first(where: { $0.name == "C_username" }),
              userCookie.value != "anonymous" else { return nil }
        return relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

extension LoginWindowController: WKHTTPCookieStoreObserver {
    // nonisolated required: WKHTTPCookieStoreObserver does not guarantee delivery
    // on @MainActor; the inner Task re-isolates to @MainActor for safety.
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // getAllCookies(_:) is the macOS 13-compatible callback form of allCookies().
            let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
                cookieStore.getAllCookies { cont.resume(returning: $0) }
            }
            guard let cookieString = LoginWindowController.rpCookieString(from: cookies) else { return }
            do {
                try await self.keychainAuth.storeCookie(cookieString)
                self.close()
            } catch {
                // Keychain write failure is non-fatal: user can retry via login window.
            }
        }
    }
}
