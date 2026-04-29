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

    private var isHandlingLogin = false

    @MainActor
    private func handleCookies(_ cookies: [HTTPCookie]) async {
        guard !isHandlingLogin else { return }
        guard let cookieString = LoginWindowController.rpCookieString(from: cookies) else { return }
        isHandlingLogin = true
        do {
            try await keychainAuth.storeCookie(cookieString)
            close()
        } catch {
            // Keychain write failure is non-fatal: user can retry via login window.
            isHandlingLogin = false
        }
    }

    override func close() {
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        super.close()
    }

    nonisolated static func rpCookieString(from cookies: [HTTPCookie]) -> String? {
        let relevant = cookies.filter {
            $0.domain.hasSuffix("radioparadise.com") &&
            ["C_username", "C_passwd", "C_validated"].contains($0.name)
        }
        // Returns nil if any of the three required RP cookies are missing or the user is anonymous.
        guard relevant.count == 3,
              let userCookie = relevant.first(where: { $0.name == "C_username" }),
              userCookie.value != "anonymous" else { return nil }
        return relevant.sorted { $0.name < $1.name }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

extension LoginWindowController: WKHTTPCookieStoreObserver {
    // nonisolated required: WKHTTPCookieStoreObserver does not guarantee delivery on @MainActor.
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        // Fetch cookies on the delivery thread (cookieStore is not Sendable — do not
        // capture it across actor boundaries). Pass the Sendable [HTTPCookie] to MainActor.
        Task {
            let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
                cookieStore.getAllCookies { cont.resume(returning: $0) }
            }
            await handleCookies(cookies)
        }
    }
}
