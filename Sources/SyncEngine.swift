import Foundation
import Photos
import BackgroundTasks
import UserNotifications

/// The core question this POC answers: can this run WITHOUT the user opening the app?
enum SyncEngine {
    // Derived from the bundle so the standalone background-test app
    // (com.travisse.pikasync.bg) registers its own task ids.
    static let refreshTaskID = "\(Bundle.main.bundleIdentifier ?? "com.travisse.pikasync").refresh"
    static let processTaskID = "\(Bundle.main.bundleIdentifier ?? "com.travisse.pikasync").process"
    private static let markerKey = "lastSyncDate"

    // MARK: - The "sync" (query new photos since last marker; no upload needed for the POC)

    static func runSync(trigger: String) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            WakeLog.record(trigger: trigger, newPhotos: -1, totalPhotos: -1, note: "no permission (\(status.rawValue))")
            return
        }
        let last = UserDefaults.standard.object(forKey: markerKey) as? Date ?? .distantPast

        let all = PHAsset.fetchAssets(with: .image, options: nil)
        let newOpts = PHFetchOptions()
        newOpts.predicate = NSPredicate(format: "creationDate > %@", last as NSDate)
        let fresh = PHAsset.fetchAssets(with: .image, options: newOpts)

        UserDefaults.standard.set(Date(), forKey: markerKey)
        WakeLog.record(trigger: trigger, newPhotos: fresh.count, totalPhotos: all.count)
        armDeadman()
    }

    /// Dead-man's switch: a local notification 4 days out, re-armed on every wake.
    /// It only ever fires if wakes STOP (force-quit, revoked access, iOS stinginess)
    /// — local notifications display even for force-quit apps.
    static func armDeadman() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["deadman"])
        let content = UNMutableNotificationContent()
        content.title = "PikaSync stopped syncing"
        content.body = "No photo checks in 4 days. Tap to resume the experiment."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 4 * 24 * 3600, repeats: false)
        center.add(UNNotificationRequest(identifier: "deadman", content: content, trigger: trigger))
    }

    // MARK: - Background task registration & scheduling

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            handle(task: task, trigger: "bg_refresh")
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processTaskID, using: nil) { task in
            handle(task: task, trigger: "bg_processing")
        }
    }

    /// Set by the main app only (nil in the BG test app): given the trigger,
    /// runs the monthly auto-book generation and returns when done.
    static var autoBookHook: (@MainActor () async -> Void)? = nil

    private static func handle(task: BGTask, trigger: String) {
        schedule()  // always re-schedule the next one first
        task.expirationHandler = {
            WakeLog.record(trigger: trigger, newPhotos: -1, totalPhotos: -1, note: "expired")
        }
        runSync(trigger: trigger)
        // The processing task's budget (minutes) is what makes full book
        // generation viable in the background — the core product question.
        if trigger == "bg_processing", let hook = autoBookHook {
            Task { @MainActor in
                await hook()
                task.setTaskCompleted(success: true)
            }
        } else {
            task.setTaskCompleted(success: true)
        }
    }

    static func schedule() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)  // ask for every 4h
        try? BGTaskScheduler.shared.submit(refresh)

        let process = BGProcessingTaskRequest(identifier: processTaskID)
        process.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 60 * 60)
        process.requiresNetworkConnectivity = true
        process.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(process)
    }

    static func requestPermission() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }
}
