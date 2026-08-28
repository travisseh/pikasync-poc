import Foundation
import PostHog
import UIKit

/// Thin PostHog wrapper. Event names are shared verbatim with the Android app
/// and the web funnel so cross-platform insights merge. Anonymous IDs only;
/// never put photo content, filenames, or asset IDs in properties.
enum Analytics {
    static let projectKey = "phc_omBAXECCW6N5Cr6YZovQYJpC6qNt4oCQ9tvkdiX9PsuR"

    private static var variant: String {
        Bundle.main.bundleIdentifier == "com.travisse.pikabook" ? "testflight" : "dev"
    }

    static func setup() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PIKA_MOCK"] == "1" { return }
        #endif
        let config = PostHogConfig(apiKey: projectKey, host: "https://us.i.posthog.com")
        config.captureApplicationLifecycleEvents = true
        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.register([
            "platform": "ios",
            "app_variant": variant,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
        ])
    }

    static func capture(_ event: String, _ props: [String: Any] = [:]) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PIKA_MOCK"] == "1" { return }
        #endif
        PostHogSDK.shared.capture(event, properties: props)
    }
}
