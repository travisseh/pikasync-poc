import AppIntents

/// The Shortcuts arm of the experiment: a personal automation (e.g. daily 9pm,
/// "Run Immediately" enabled) can invoke this with the app closed. iOS runs the
/// intent in-process without opening the UI.
struct SyncPhotosIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Photos Now"
    static var description = IntentDescription("Checks for new photos and logs a wake event.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        SyncEngine.runSync(trigger: "shortcut")
        // Main app only (hook is nil in the BG test app): the nightly shortcut
        // is the most reliable wake we have, so let it also drive the monthly
        // book. The once-per-month marker makes this idempotent.
        if let hook = SyncEngine.autoBookHook {
            await hook("shortcut")
        }
        return .result()
    }
}

struct PikaSyncShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncPhotosIntent(),
                    phrases: ["Sync photos with \(.applicationName)"],
                    shortTitle: "Sync Photos",
                    systemImageName: "photo.stack")
    }
}
