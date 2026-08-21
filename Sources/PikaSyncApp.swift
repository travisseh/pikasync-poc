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
            RootView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                SyncEngine.schedule()
            }
        }
    }
}

struct RootView: View {
    @StateObject private var scanner = PeopleScanner()

    var body: some View {
        TabView {
            BooksTab(scanner: scanner)
                .tabItem { Label("Books", systemImage: "book.pages") }
            NavigationStack { PeoplePickerView(scanner: scanner) }
                .tabItem { Label("People", systemImage: "person.2") }
            NavigationStack { SyncView() }
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
        }
        .onAppear {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }
}

// MARK: - Books (main tab)

struct BooksTab: View {
    @ObservedObject var scanner: PeopleScanner
    @ObservedObject private var runStore = RunStore.shared
    @ObservedObject private var people = PeopleStore.shared

    var body: some View {
        NavigationStack {
            List {
                if people.clusters.isEmpty && !scanner.hasScanned {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Set up: find your people").font(.headline)
                            Text("Pikabook scans your last 6 months of photos to learn who your books are about. You then name and star your family.")
                                .font(.caption).foregroundStyle(.secondary)
                            if scanner.scanning {
                                ProgressView(value: scanner.progress)
                                Text(scanner.statusText).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("Scan my photos") {
                                    Task { await scanner.scan() }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    NavigationLink {
                        PipelineView()
                    } label: {
                        Label("Create a book", systemImage: "plus.circle.fill")
                            .font(.headline)
                    }
                }

                Section(runStore.runs.isEmpty ? "" : "Your books") {
                    if runStore.runs.isEmpty {
                        Text("No books yet — create your first one above.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(runStore.runs) { run in
                        NavigationLink {
                            SavedBookView(run: run)
                        } label: {
                            HStack(spacing: 12) {
                                if let data = run.coverThumbJPEG, let img = UIImage(data: data) {
                                    Image(uiImage: img)
                                        .resizable().scaledToFill()
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(run.title).font(.headline)
                                    Text("\(run.monthLabel) · \(run.selections.count) photos")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(run.createdAt, format: .dateTime.month().day().hour().minute())
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .onDelete { idx in
                        idx.map { runStore.runs[$0].id }.forEach { runStore.delete($0) }
                    }
                }
            }
            .navigationTitle("Pikabook")
        }
    }
}

// MARK: - Saved book viewer

struct SavedBookView: View {
    let run: SavedRun
    @State private var images: [String: UIImage] = [:]

    private var pages: [SavedRun.Selection] { run.selections.sorted { $0.page < $1.page } }

    var body: some View {
        TabView {
            VStack(spacing: 16) {
                if let img = images[run.coverAssetID] {
                    Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text(run.title).font(.title).bold().multilineTextAlignment(.center)
            }
            .padding().tag(-1)

            ForEach(pages, id: \.page) { sel in
                VStack(spacing: 12) {
                    if let img = images[sel.assetID] {
                        Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        ProgressView()
                    }
                    Text(sel.caption).font(.headline)
                    Text("page \(sel.page)").font(.caption).foregroundStyle(.secondary)
                }
                .padding().tag(sel.page)
            }
        }
        .tabViewStyle(.page)
        .navigationTitle(run.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let ids = pages.map(\.assetID) + [run.coverAssetID]
            images = await AssetLoader.load(ids: Array(Set(ids)), size: CGSize(width: 1600, height: 1600))
        }
    }
}

// MARK: - Sync (experiment tab)

struct SyncView: View {
    @State private var events: [WakeEvent] = []
    @State private var authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var body: some View {
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
        .navigationTitle("Background sync")
        .onAppear { events = WakeLog.load() }
        .refreshable { events = WakeLog.load() }
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
