import Foundation

// SwiftPM's auto-generated `Bundle.module` resolves the resource bundle via
// `Bundle.main.bundleURL.appendingPathComponent("RPPlayer_RPPlayer.bundle")`.
// For a .app, Bundle.main.bundleURL is the .app dir itself — but macOS
// convention puts resources at <App>.app/Contents/Resources/, where SPM
// never looks. Touching `Bundle.module` therefore fatalErrors at launch for
// any .app that doesn't also stash a copy at the .app root.
//
// `AppResources.bundle` checks Contents/Resources/ first and falls back to
// `Bundle.module` only if that path fails — so `swift run` and tests still
// work the same way they always did.
enum AppResources {
    static let bundle: Bundle = {
        if let resourcesURL = Bundle.main.resourceURL {
            let candidate = resourcesURL.appendingPathComponent("RPPlayer_RPPlayer.bundle")
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return Bundle.module
    }()
}
