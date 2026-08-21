import SwiftUI
import Photos
import UserNotifications

@main
struct PikaSyncApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SyncEngine.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                SyncEngine.schedule()
            }
        }
    }
}

struct ContentView: View {
    @State private var events: [WakeEvent] = []
    @State private var authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var body: some View {
        NavigationStack {
            List {
                Section("Setup") {
                    HStack {
                        Text("Photos access")
                        Spacer()
                        Text(label(for: authStatus)).foregroundStyle(.secondary)
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
                }
                Section("Photobook") {
                    NavigationLink("Photobook pipeline") { PipelineView() }
                    NavigationLink("People") { PeoplePickerView() }
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
            .navigationTitle("PikaSync POC")
            .onAppear {
                events = WakeLog.load()
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
            .refreshable { events = WakeLog.load() }
        }
    }

    private func label(for status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: "Full"
        case .limited: "Limited"
        case .denied: "Denied"
        case .notDetermined: "Not asked"
        default: "Other"
        }
    }
}
