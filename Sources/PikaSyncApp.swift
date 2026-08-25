import SwiftUI
import Photos
import UserNotifications

@main
struct PikaSyncApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SyncEngine.register()
        SyncEngine.autoBookHook = { trigger in await AutoBook.tick(trigger: trigger) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                SyncEngine.schedule()
            } else if phase == .active {
                RemoteCommand.checkAndRun()
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
    @State private var confirmDelete = false
    @State private var currentPage = -1
    @State private var shareURL: String?
    @State private var shareID: String?
    @State private var shareStatus: String?
    @State private var showShareSheet = false
    @State private var showFeedback = false
    @Environment(\.dismiss) private var dismiss

    private var pages: [SavedRun.Selection] { run.selections.sorted { $0.page < $1.page } }

    var body: some View {
        TabView(selection: $currentPage) {
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
                    Text("page \(sel.page)").font(.caption).foregroundStyle(.secondary)
                }
                .padding().tag(sel.page)
            }
        }
        .tabViewStyle(.page)
        .navigationTitle(run.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFeedback = true } label: {
                    Image(systemName: "bubble.left")
                }
                .disabled(shareID == nil && shareURL == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if shareStatus != nil {
                    ProgressView()
                } else {
                    Button { Task { await share() } } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let status = shareStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .padding(6).frame(maxWidth: .infinity).background(.thinMaterial)
            }
        }
        .confirmationDialog("Delete this book?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(run.title)", role: .destructive) {
                RunStore.shared.delete(run.id)
                dismiss()
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let shareURL, let url = URL(string: shareURL) {
                ActivityView(items: [url])
            }
        }
        .sheet(isPresented: $showFeedback) {
            if let shareID {
                FeedbackSheet(shareID: shareID,
                              page: currentPage == -1 ? 0 : currentPage,
                              pageLabel: currentPage == -1 ? "cover" : "page \(currentPage)")
                    .presentationDetents([.medium])
            }
        }
        .task {
            shareURL = run.shareURL
            shareID = run.shareID
            let ids = pages.map(\.assetID) + [run.coverAssetID]
            images = await AssetLoader.load(ids: Array(Set(ids)), size: CGSize(width: 1600, height: 1600))
        }
    }

    private func share() async {
        if shareURL != nil {  // already uploaded — straight to the share sheet
            showShareSheet = true
            return
        }
        do {
            let result = try await ShareClient.upload(run: run) { shareStatus = $0 }
            shareStatus = nil
            shareURL = result.url
            shareID = result.shareID
            RunStore.shared.setShare(id: run.id, shareURL: result.url, shareID: result.shareID)
            showShareSheet = true
        } catch {
            shareStatus = "share failed: \(error)"
            try? await Task.sleep(for: .seconds(4))
            shareStatus = nil
        }
    }
}

/// Per-photo feedback from inside the app; lands in the same Convex table
/// that share-link viewers write to.
struct FeedbackSheet: View {
    let shareID: String
    let page: Int
    let pageLabel: String
    @State private var reaction: String?
    @State private var text = ""
    @State private var status: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Reaction", selection: $reaction) {
                    Text("❤️ Love").tag(String?.some("love"))
                    Text("😐 Meh").tag(String?.some("meh"))
                    Text("✂️ Cut").tag(String?.some("cut"))
                    Text("none").tag(String?.none)
                }
                .pickerStyle(.segmented)
                TextField("Details (optional)", text: $text, axis: .vertical)
                    .lineLimit(3...6)
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("Feedback · \(pageLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task {
                            status = "sending…"
                            do {
                                try await ShareClient.sendFeedback(
                                    shareID: shareID, page: page,
                                    reaction: reaction, text: text)
                                dismiss()
                            } catch { status = "failed: \(error)" }
                        }
                    }
                    .disabled(reaction == nil && text.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
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
