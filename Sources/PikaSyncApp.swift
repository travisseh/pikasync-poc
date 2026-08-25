import SwiftUI
import Photos
import UserNotifications

@main
struct PikaSyncApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SyncEngine.register()
        SyncEngine.autoBookHook = { trigger in await AutoBook.tick(trigger: trigger) }

        // Normal solid bottom nav: white, hairline top edge.
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = .white
        // Push icons/labels down from the bar's top edge for breathing room.
        for item in [tabAppearance.stackedLayoutAppearance,
                     tabAppearance.inlineLayoutAppearance,
                     tabAppearance.compactInlineLayoutAppearance] {
            item.normal.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: 6)
            item.selected.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: 6)
        }
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        // NOTE: UITabBarItem.appearance().imageInsets crashes SwiftUI TabView
        // (UIKit applies it off-main). Icon padding needs a custom bar instead.
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Pika.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                SyncEngine.schedule()
            } else if phase == .active {
                RemoteCommand.checkAndRun()
                Task { await ShareClient.sweepUnshared() }
            }
        }
    }
}

struct RootView: View {
    @StateObject private var scanner = PeopleScanner()
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            BooksTab(scanner: scanner)
                .tabItem { Label("Books", systemImage: "book.pages") }.tag(0)
            NavigationStack { PeoplePickerView(scanner: scanner) }
                .tabItem { Label("People", systemImage: "person.2") }.tag(1)
            NavigationStack { SyncView() }
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }.tag(2)
        }
        #if DEBUG
        .onAppear {
            switch ProcessInfo.processInfo.environment["PIKA_SCREEN"] {
            case "people": tab = 1
            case "sync": tab = 2
            default: break
            }
        }
        #endif
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["PIKA_MOCK"] == "1" { return }
            #endif
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        #if DEBUG
        .task { await MockSeeder.seedIfRequested() }
        #endif
    }
}

// MARK: - Books (main tab)

struct BooksTab: View {
    @ObservedObject var scanner: PeopleScanner
    @ObservedObject private var runStore = RunStore.shared
    @ObservedObject private var people = PeopleStore.shared
    @ObservedObject private var coordinator = CreateCoordinator.shared
    @State private var showCreate = false
    @State private var progressBuild: CreateCoordinator.Build?
    #if DEBUG
    @State private var autoOpenBook = false
    @State private var autoOpenPipeline = false
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if people.clusters.isEmpty && !scanner.hasScanned {
                        welcomeCard
                    }

                    if runStore.runs.isEmpty && coordinator.builds.isEmpty {
                        emptyState
                    }

                    ForEach(coordinator.builds) { build in
                        Button {
                            progressBuild = build
                        } label: {
                            BuildingCard(build: build)
                        }
                        .buttonStyle(PressCardStyle())
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    ForEach(runStore.runs) { run in
                        NavigationLink {
                            SavedBookView(run: run)
                        } label: {
                            BookCard(run: run)
                        }
                        .buttonStyle(PressCardStyle())
                        .contextMenu {
                            Button(role: .destructive) {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    runStore.delete(run.id)
                                }
                            } label: {
                                Label("Delete book", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 96)
            }
            .background(Pika.bg)
            .navigationTitle("Your books")
            .overlay(alignment: .bottomTrailing) {
                CreateFAB { showCreate = true }
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
            }
            .sheet(isPresented: $showCreate) { CreateSheet() }
            .sheet(item: $progressBuild) { build in
                BuildProgressSheet(build: build)
            }
            #if DEBUG
            .navigationDestination(isPresented: $autoOpenBook) {
                if let run = runStore.runs.first { SavedBookView(run: run) }
            }
            .task {
                let screen = ProcessInfo.processInfo.environment["PIKA_SCREEN"]
                if screen == "create" { showCreate = true; return }
                if screen == "building" {
                    let build = CreateCoordinator.Build(month: Calendar.current.date(byAdding: .month, value: -1, to: Date())!)
                    build.runner.status = "scoring 62/206"
                    build.runner.stageTimes = [
                        .init(name: "scoring", seconds: 4.2, detail: "206 in month, 62 newly scored"),
                    ]
                    coordinator.builds = [build]
                    return
                }
                guard ["book", "actions", "feedback", "delete", "pipeline", "detail", "spread"].contains(screen ?? "") else { return }
                for _ in 0..<50 where runStore.runs.isEmpty {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if screen == "pipeline" { autoOpenPipeline = true }
                else if !runStore.runs.isEmpty { autoOpenBook = true }
            }
            .navigationDestination(isPresented: $autoOpenPipeline) { PipelineView() }
            #endif
        }
    }

    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find your people")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Pika.ink)
            Text("Pikabook scans your last 6 months of photos to learn who your books are about. You name and star your family once — every book uses it.")
                .font(.system(size: 15))
                .foregroundStyle(Pika.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if scanner.scanning {
                ProgressView(value: scanner.progress)
                    .tint(Pika.accent)
                Text(scanner.statusText)
                    .font(.system(size: 13))
                    .foregroundStyle(Pika.inkSecondary)
            } else {
                Button("Scan my photos") {
                    Task { await scanner.scan() }
                }
                .buttonStyle(PillButtonStyle())
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: Pika.cardRadius).fill(Pika.bgSoft))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No books yet")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Pika.ink)
            Text("Your first monthly book is one tap away.")
                .font(.system(size: 15))
                .foregroundStyle(Pika.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

/// The photo IS the card: edge-to-edge cover, scrim, overlaid title.
struct BookCard: View {
    let run: SavedRun

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let data = run.coverThumbJPEG, let img = UIImage(data: data) {
                    Color.clear.overlay(
                        Image(uiImage: img).resizable().scaledToFill()
                    )
                } else {
                    Pika.bgSoft.overlay(
                        Image(systemName: "book.pages")
                            .font(.system(size: 40))
                            .foregroundStyle(Pika.inkSecondary)
                    )
                }
            }
            .frame(height: 300)
            .clipped()
            .overlay(Scrim())

            VStack(alignment: .leading, spacing: 3) {
                Text(run.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(run.monthLabel) · \(run.selections.count) photos")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(18)
        }
        .clipShape(RoundedRectangle(cornerRadius: Pika.cardRadius))
        .pikaShadow()
    }
}

// MARK: - Saved book viewer

struct SavedBookView: View {
    let run: SavedRun
    @State private var images: [String: UIImage] = [:]
    @State private var unit = 0
    @State private var shareURL: String?
    @State private var shareID: String?
    @State private var shareStatus: String?
    @State private var showShareSheet = false
    @State private var showFeedback = false
    @State private var showActions = false
    @State private var showPipelineDetails = false
    @State private var confirmDelete = false
    @State private var detail: PageDetail?
    @Environment(\.dismiss) private var dismiss

    struct PageDetail: Identifiable {
        let assetID: String
        let page: Int
        var id: Int { page }
    }

    private var pages: [SavedRun.Selection] { run.selections.sorted { $0.page < $1.page } }
    /// Pages after the title page, paired into spreads.
    private var spreads: [[SavedRun.Selection]] {
        stride(from: 0, to: pages.count, by: 2).map { Array(pages[$0..<min($0 + 2, pages.count)]) }
    }

    var body: some View {
        TabView(selection: $unit) {
            titlePage.tag(0)
            ForEach(Array(spreads.enumerated()), id: \.offset) { i, pair in
                SpreadView(pair: pair, images: images) { sel in
                    detail = PageDetail(assetID: sel.assetID, page: sel.page)
                }
                .tag(i + 1)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .indexViewStyle(.page(backgroundDisplayMode: .never))
        .background(Pika.bg)
        .navigationTitle(run.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await share() } } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await openFeedback() } } label: {
                    Image(systemName: "bubble.left")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showActions = true } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let status = shareStatus {
                Text(status)
                    .font(.system(size: 13))
                    .foregroundStyle(Pika.inkSecondary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: shareStatus)
        .sheet(isPresented: $showActions) { actionsSheet }
        .sheet(isPresented: $confirmDelete) { deleteSheet }
        .sheet(isPresented: $showPipelineDetails) { pipelineDetailsSheet }
        .sheet(isPresented: $showShareSheet) {
            if let shareURL, let url = URL(string: shareURL) {
                ActivityView(items: [url])
            }
        }
        .sheet(isPresented: $showFeedback) {
            if let shareID {
                FeedbackSheet(shareID: shareID, page: nil, pageLabel: "this book")
                    .presentationDetents([.medium])
                    .presentationCornerRadius(Pika.sheetRadius)
            }
        }
        .fullScreenCover(item: $detail) { d in
            PhotoDetailView(
                image: images[d.assetID],
                page: d.page,
                ensureShareID: { await ensureShared() ? shareID : nil })
        }
        .task {
            shareURL = run.shareURL
            shareID = run.shareID
            let ids = pages.map(\.assetID) + [run.coverAssetID]
            images = await AssetLoader.load(ids: Array(Set(ids)), size: CGSize(width: 1600, height: 1600))
            #if DEBUG
            switch ProcessInfo.processInfo.environment["PIKA_SCREEN"] {
            case "actions": showActions = true
            case "delete": confirmDelete = true
            case "feedback": shareID = shareID ?? "mock-design-preview"; showFeedback = true
            case "detail":
                if let first = pages.first { detail = PageDetail(assetID: first.assetID, page: first.page) }
            case "spread":
                unit = 1
            default: break
            }
            #endif
        }
    }

    /// Title page: one square photo + the book title, like a printed cover.
    private var titlePage: some View {
        VStack(spacing: 24) {
            SquarePhoto(image: images[run.coverAssetID])
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 36)
                .pikaShadow()
                .onTapGesture {
                    detail = PageDetail(assetID: run.coverAssetID, page: 0)
                }
            VStack(spacing: 6) {
                Text(run.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Pika.ink)
                    .multilineTextAlignment(.center)
                Text(run.monthLabel)
                    .font(.system(size: 15))
                    .foregroundStyle(Pika.inkSecondary)
            }
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 20)
    }

    private var pipelineDetailsSheet: some View {
        VStack(spacing: 14) {
            Capsule().fill(Pika.hairline).frame(width: 36, height: 4).padding(.top, 10)
            Text("Pipeline details")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Pika.ink)
            ScrollView {
                StageListView(stages: run.stages ?? [], judgeInfo: run.judgeInfo)
                    .padding(.horizontal, 20)
                if run.stages == nil {
                    Text("No stage data for this book (made before pipeline details were saved).")
                        .font(.system(size: 14))
                        .foregroundStyle(Pika.inkSecondary)
                        .padding(20)
                }
            }
        }
        .background(Pika.bg)
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(Pika.sheetRadius)
    }

    private var actionsSheet: some View {
        VStack(spacing: 12) {
            Capsule().fill(Pika.hairline).frame(width: 36, height: 4).padding(.top, 10)
            Text(run.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Pika.ink)
                .padding(.top, 4)

            VStack(spacing: 10) {
                Button {
                    showActions = false
                    Task { await share() }
                } label: {
                    Label("Share book", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PillButtonStyle())


                Button {
                    showActions = false
                    showPipelineDetails = true
                } label: {
                    Label("Pipeline details", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(PillButtonStyle(filled: false))

                Button {
                    showActions = false
                    confirmDelete = true
                } label: {
                    Label("Delete book", systemImage: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            Spacer(minLength: 12)
        }
        .presentationDetents([.height(338)])
        .presentationCornerRadius(Pika.sheetRadius)
        .background(Pika.bg)
    }

    private var deleteSheet: some View {
        VStack(spacing: 14) {
            Capsule().fill(Pika.hairline).frame(width: 36, height: 4).padding(.top, 10)
            Text("Delete this book?")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Pika.ink)
                .padding(.top, 8)
            Text("\"\(run.title)\" will be removed from your books. Your photos stay in your library.")
                .font(.system(size: 15))
                .foregroundStyle(Pika.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button("Delete book") {
                confirmDelete = false
                RunStore.shared.delete(run.id)
                dismiss()
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Capsule().fill(.red))
            .padding(.horizontal, 20)

            Button("Cancel") { confirmDelete = false }
                .buttonStyle(PillButtonStyle(filled: false))
                .padding(.horizontal, 20)
            Spacer(minLength: 12)
        }
        .presentationDetents([.height(310)])
        .presentationCornerRadius(Pika.sheetRadius)
        .background(Pika.bg)
    }

    private func share() async {
        guard await ensureShared() else { return }
        showShareSheet = true
    }

    /// Feedback works before the book was ever shared: lazily create the
    /// server book on first tap, exactly like share does.
    private func openFeedback() async {
        guard await ensureShared() else { return }
        showFeedback = true
    }

    /// Uploads once (via the shared idempotent path), caches the link.
    private func ensureShared() async -> Bool {
        if shareURL != nil, shareID != nil { return true }
        if let result = await ShareClient.ensureShared(runID: run.id, progress: { shareStatus = $0 }) {
            shareStatus = nil
            shareURL = result.url
            shareID = result.shareID
            return true
        }
        shareStatus = "share failed — check your connection"
        try? await Task.sleep(for: .seconds(4))
        shareStatus = nil
        return false
    }
}

// MARK: - Spread layout (square photos, two per page like a printed book)

/// Square crop, top-anchored so faces survive the crop.
struct SquarePhoto: View {
    let image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    GeometryReader { geo in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                            .clipped()
                    }
                } else {
                    Pika.bgSoft.overlay(ProgressView())
                }
            }
            .clipped()
    }
}

/// One spread: two squares side by side on a white "page" card.
struct SpreadView: View {
    let pair: [SavedRun.Selection]
    let images: [String: UIImage]
    let onTap: (SavedRun.Selection) -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                ForEach(pair, id: \.page) { sel in
                    Button { onTap(sel) } label: {
                        SquarePhoto(image: images[sel.assetID])
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(PressCardStyle())
                }
                if pair.count == 1 {
                    // Last odd page: blank facing page keeps the book feel.
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Pika.bgSoft)
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: Pika.cardRadius)
                    .fill(.white)
            )
            .pikaShadow()
            .padding(.horizontal, 16)
            Spacer()
        }
    }
}

/// Tap a square → the photo full size (uncropped) with per-photo feedback.
struct PhotoDetailView: View {
    let image: UIImage?
    let page: Int
    let ensureShareID: () async -> String?
    @State private var shareID: String?
    @State private var showFeedback = false
    @State private var preparing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Pika.bg.ignoresSafeArea()
            VStack {
                Spacer()
                if let image {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .pikaShadow()
                        .padding(.horizontal, 16)
                } else {
                    ProgressView()
                }
                Spacer()
                Button {
                    Task {
                        preparing = true
                        shareID = await ensureShareID()
                        preparing = false
                        if shareID != nil { showFeedback = true }
                    }
                } label: {
                    if preparing {
                        ProgressView().tint(.white).frame(maxWidth: .infinity).frame(height: 52)
                            .background(Capsule().fill(Pika.accent))
                    } else {
                        Label("Feedback on this photo", systemImage: "bubble.left")
                    }
                }
                .buttonStyle(PillButtonStyle())
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Pika.ink)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Pika.bgSoft))
            }
            .padding(16)
        }
        .sheet(isPresented: $showFeedback) {
            if let shareID {
                FeedbackSheet(shareID: shareID, page: page,
                              pageLabel: page == 0 ? "cover" : "photo \(page)")
                    .presentationDetents([.medium])
                    .presentationCornerRadius(Pika.sheetRadius)
            }
        }
    }
}

/// Per-photo feedback from inside the app; lands in the same Convex table
/// that share-link viewers write to.
struct FeedbackSheet: View {
    let shareID: String
    let page: Int?
    let pageLabel: String
    @State private var reaction: String?
    @State private var text = ""
    @State private var status: String?
    @Environment(\.dismiss) private var dismiss

    private let reactions: [(String, String)] = [("love", "❤️"), ("meh", "😐"), ("cut", "✂️")]

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(Pika.hairline).frame(width: 36, height: 4).padding(.top, 10)
            Text("Feedback · \(pageLabel)")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Pika.ink)

            HStack(spacing: 14) {
                ForEach(reactions, id: \.0) { key, emoji in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            reaction = (reaction == key) ? nil : key
                        }
                    } label: {
                        Text(emoji)
                            .font(.system(size: 30))
                            .frame(width: 64, height: 56)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(reaction == key ? Pika.accent.opacity(0.12) : Pika.bgSoft)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(reaction == key ? Pika.accent : .clear, lineWidth: 1.5)
                            )
                            .scaleEffect(reaction == key ? 1.06 : 1)
                    }
                }
            }

            TextField("Add details (optional)", text: $text, axis: .vertical)
                .lineLimit(3...5)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Pika.bgSoft))
                .padding(.horizontal, 20)

            if let status {
                Text(status).font(.system(size: 13)).foregroundStyle(Pika.inkSecondary)
            }

            Button("Send feedback") {
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
            .buttonStyle(PillButtonStyle())
            .disabled(reaction == nil && text.isEmpty)
            .opacity(reaction == nil && text.isEmpty ? 0.4 : 1)
            .padding(.horizontal, 20)
            Spacer(minLength: 12)
        }
        .background(Pika.bg)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Sync (experiment tab; dev surface, light touch)

struct SyncView: View {
    @State private var events: [WakeEvent] = []
    @State private var authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var body: some View {
        List {
            Section("Setup") {
                HStack {
                    Text("Photos access")
                    Spacer()
                    Text(label(for: authStatus)).foregroundStyle(Pika.inkSecondary)
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
                    .font(.caption).foregroundStyle(Pika.inkSecondary)
                    .textSelection(.enabled)
            }
            Section("Wake log (\(events.count))") {
                if events.isEmpty {
                    Text("No wakes recorded yet").foregroundStyle(Pika.inkSecondary)
                }
                ForEach(events) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(e.trigger).bold()
                            Spacer()
                            Text(e.timestamp, format: .dateTime.month().day().hour().minute())
                                .foregroundStyle(Pika.inkSecondary)
                        }
                        Text("new: \(e.newPhotos)  total: \(e.totalPhotos) \(e.note)")
                            .font(.caption).foregroundStyle(Pika.inkSecondary)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Pika.bg)
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

#if DEBUG
/// Simulator-only: `PIKA_MOCK=1` seeds two fake saved books from the photo
/// library so the Books tab can be designed against real-looking content.
enum MockSeeder {
    @MainActor
    static func seedIfRequested() async {
        func trace(_ s: String) {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("mock-debug.txt")
            let line = s + "\n"
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)) }
            else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
        guard ProcessInfo.processInfo.environment["PIKA_MOCK"] == "1",
              RunStore.shared.runs.isEmpty else { return }

        // No PhotoKit: read JPEGs copied into Documents/mock-photos (permission
        // prompts can't be answered in an unattended simulator).
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mock-photos")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") }
            .sorted()
        trace("mock-photos files=\(files.count)")
        guard files.count >= 4 else { return }
        let ids = files.prefix(12).map { "mock:\($0)" }

        let thumbs = await AssetLoader.load(ids: [ids[0], ids[min(6, ids.count - 1)]],
                                            size: CGSize(width: 600, height: 600))
        func run(title: String, month: String, cover: String, pageIDs: [String]) -> SavedRun {
            SavedRun(id: UUID(), createdAt: Date(), monthLabel: month, title: title,
                     coverAssetID: cover,
                     selections: pageIDs.enumerated().map { .init(assetID: $1, page: $0 + 1) },
                     totalSeconds: 42, judgeInfo: "mock",
                     coverThumbJPEG: thumbs[cover]?.jpegData(compressionQuality: 0.8))
        }
        let half = ids.count / 2
        RunStore.shared.add(run(title: "Beach Days & Disney Castles", month: "May 2026",
                                cover: ids[0], pageIDs: Array(ids[0..<half])))
        RunStore.shared.add(run(title: "Carson's Summer of Sunshine", month: "July 2026",
                                cover: ids[min(6, ids.count - 1)], pageIDs: Array(ids[half...])))

        // Mock people so the People grid can be designed against content.
        if PeopleStore.shared.clusters.isEmpty {
            let specs: [(String, PersonCluster.Role, Int)] = [
                ("Travisse", .required, 198), ("Steph", .required, 211),
                ("Carson", .required, 356), ("", .neutral, 24), ("", .excluded, 9),
            ]
            for (i, spec) in specs.enumerated() {
                let file = files[min(i, files.count - 1)]
                let img = UIImage(contentsOfFile: dir.appendingPathComponent(file).path)
                let side = min(img?.size.width ?? 200, img?.size.height ?? 200) / 2
                let crop = img.flatMap { im -> UIImage? in
                    let r = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200))
                    return r.image { _ in
                        im.draw(in: CGRect(x: -side / 4, y: -side / 4, width: 400, height: 400 * (im.size.height / max(im.size.width, 1))))
                    }
                }
                PeopleStore.shared.clusters.append(PersonCluster(
                    id: UUID(), name: spec.0, role: spec.1,
                    centroid: [], count: spec.2,
                    repCropPNG: crop?.pngData()))
            }
            PeopleStore.shared.save()
        }
    }
}
#endif
