import SwiftUI
import Photos
import UserNotifications

/// Standalone background-sync experiment app (com.travisse.pikasync.bg).
/// Identical sync mechanics to the main app, but nothing else — so the 7-day
/// no-touch test stays clean while the main Pikabook app gets iterated on.
/// Logs to ntfy.sh/pikasync-bg-trav-8347 (topic derived from bundle id).
@main
struct PikaSyncBGApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SyncEngine.register()
    }

    var body: some Scene {
        WindowGroup {
            BGContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                SyncEngine.schedule()
            }
        }
    }
}

struct BGContentView: View {
    @State private var events: [WakeEvent] = []
    @State private var authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var body: some View {
        NavigationStack {
            List {
                Section("Setup") {
                    HStack {
                        Text("Photos access")
                        Spacer()
                        Text(authStatus == .authorized ? "Full" : authStatus == .limited ? "Limited" : "Not granted")
                            .foregroundStyle(.secondary)
                    }
                    if authStatus != .authorized {
                        Button("Request full access") {
                            Task {
                                await SyncEngine.requestPermission()
                                authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                            }
                        }
                    }
                    Button("Sync now (foreground)") {
                        SyncEngine.runSync(trigger: "foreground")
                        events = WakeLog.load()
                    }
                    Text("Wake beacon: ntfy.sh/\(WakeLog.ntfyTopic)")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("After setup: background this app and DON'T open it again. Wakes appear on the beacon; the 4-day dead-man notification fires only if wakes stop.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Wake log (\(events.count))") {
                    if events.isEmpty {
                        Text("No wakes recorded yet").foregroundStyle(.secondary)
                    }
                    ForEach(events) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(e.trigger).bold()
                                Spacer()
                                Text(e.timestamp, format: .dateTime.month().day().hour().minute())
                                    .foregroundStyle(.secondary)
                            }
                            Text("new: \(e.newPhotos)  total: \(e.totalPhotos) \(e.note)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("PikaSync BG Test")
            .onAppear {
                events = WakeLog.load()
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
            .refreshable { events = WakeLog.load() }
        }
    }
}
