import SwiftUI
import Photos

/// First-run onboarding: welcome → "your people" intro → permission priming →
/// fast 60-day people scan → pick who books center on (top 3 pre-selected) →
/// auto-create last month's book. Shown only when the app has no people and
/// no books; existing users never see it.
enum OnboardingState {
    static let doneKey = "onboardingDone"
    static var done: Bool {
        get { UserDefaults.standard.bool(forKey: doneKey) }
        set { UserDefaults.standard.set(newValue, forKey: doneKey) }
    }

    @MainActor
    static var shouldShow: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["PIKA_SCREEN"]?.hasPrefix("onboarding") == true { return true }
        // Mock design sessions target the main UI; never cover it with onboarding.
        if env["PIKA_MOCK"] == "1" { return false }
        #endif
        return !done && PeopleStore.shared.clusters.isEmpty && RunStore.shared.runs.isEmpty
    }
}

struct OnboardingFlow: View {
    @ObservedObject var scanner: PeopleScanner
    let finished: () -> Void

    enum Step { case welcome, tagIntro, permission, denied, scanning, people }
    @State private var step: Step = .welcome
    @State private var limitedAccess = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Pika.bg.ignoresSafeArea()
            switch step {
            case .welcome: welcome
            case .tagIntro: tagIntro
            case .permission: permission
            case .denied: denied
            case .scanning: scanning
            case .people: people
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
        .onChange(of: scenePhase) { _, phase in
            // Coming back from Settings after granting access.
            if phase == .active && step == .denied {
                let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if status == .authorized || status == .limited {
                    limitedAccess = status == .limited
                    step = .scanning
                }
            }
        }
        #if DEBUG
        .onAppear {
            switch ProcessInfo.processInfo.environment["PIKA_SCREEN"] {
            case "onboarding-tag": step = .tagIntro
            case "onboarding-permission": step = .permission
            case "onboarding-denied": step = .denied
            case "onboarding-scanning": step = .scanning
            case "onboarding-people": step = .people
            default: break
            }
        }
        #endif
    }

    // MARK: welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            momentsCollage
                .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 12) {
                Text("Your month,\nalready a book")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Pika.ink)
                    .multilineTextAlignment(.center)
                Text("Pikabook turns your camera roll into a monthly photobook, automatically. No sorting, no picking. It happens while you live your life.")
                    .font(.system(size: 16))
                    .foregroundStyle(Pika.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            Button("Get started") { step = .tagIntro }
                .buttonStyle(PillButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
        }
        .transition(.opacity)
    }

    /// Warm photo-shaped collage for the welcome screen (no photos exist yet,
    /// so evoke a book: three overlapping "pages" in brand tones).
    private var momentsCollage: some View {
        ZStack {
            page(color: Pika.accent.opacity(0.14), icon: nil, rotation: -8, offset: CGSize(width: -58, height: 12))
            page(color: Pika.bgSoft, icon: nil, rotation: 7, offset: CGSize(width: 62, height: 22))
            page(color: Pika.accent, icon: "heart.fill", rotation: 0, offset: .zero, prominent: true)
        }
        .frame(height: 240)
    }

    private func page(color: Color, icon: String?, rotation: Double, offset: CGSize, prominent: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(color)
            .frame(width: 148, height: 190)
            .overlay {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 40))
                        .foregroundStyle(prominent ? .white : Pika.accent.opacity(0.55))
                }
            }
            .rotationEffect(.degrees(rotation))
            .offset(offset)
            .pikaShadow()
    }

    // MARK: tag intro

    private var tagIntro: some View {
        VStack(spacing: 0) {
            Spacer()
            facesCollage
            Spacer()
            VStack(spacing: 12) {
                Text("Books about\nyour people")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Pika.ink)
                    .multilineTextAlignment(.center)
                Text("Pikabook finds who shows up most in your photos, so every book centers on the people you love. Not screenshots, not strangers, not receipts.")
                    .font(.system(size: 16))
                    .foregroundStyle(Pika.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            Button("Find my people") {
                let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if status == .authorized || status == .limited {
                    limitedAccess = status == .limited
                    step = .scanning
                } else {
                    step = .permission
                }
            }
            .buttonStyle(PillButtonStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .transition(.opacity)
    }

    /// Overlapping "face" circles in brand tones.
    private var facesCollage: some View {
        ZStack {
            faceCircle(color: Pika.accent.opacity(0.14), size: 104, offset: CGSize(width: -76, height: 18))
            faceCircle(color: Pika.bgSoft, size: 96, offset: CGSize(width: 78, height: 26))
            Circle()
                .fill(Pika.accent)
                .frame(width: 132, height: 132)
                .overlay(
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.white)
                )
                .pikaShadow()
        }
        .frame(height: 200)
    }

    private func faceCircle(color: Color, size: CGFloat, offset: CGSize) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(Pika.accent.opacity(0.4))
            )
            .offset(offset)
    }

    // MARK: permission

    private var permission: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(Pika.accent)
                .padding(28)
                .background(Circle().fill(Pika.accent.opacity(0.1)))
            Spacer().frame(height: 32)
            VStack(spacing: 12) {
                Text("Pikabook needs your photos")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Pika.ink)
                    .multilineTextAlignment(.center)
                Text("Books are made from your whole month, so full access matters: with only a few selected photos, Pikabook can't find the moments worth keeping. Your photos stay on your phone: only three small preview grids ever leave it.")
                    .font(.system(size: 16))
                    .foregroundStyle(Pika.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            Spacer()
            VStack(spacing: 10) {
                Button("Allow access") {
                    Task {
                        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                        switch status {
                        case .authorized:
                            limitedAccess = false
                            step = .scanning
                        case .limited:
                            limitedAccess = true
                            step = .scanning
                        default:
                            step = .denied
                        }
                    }
                }
                .buttonStyle(PillButtonStyle())
                Button("Not now") { finish(startBook: false) }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Pika.inkSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .transition(.opacity)
    }

    private var denied: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "lock.circle")
                .font(.system(size: 56))
                .foregroundStyle(Pika.inkSecondary)
            Spacer().frame(height: 28)
            VStack(spacing: 12) {
                Text("Photo access is off")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Pika.ink)
                Text("Pikabook can't make books without your photos. You can turn on access in Settings. It only takes a second.")
                    .font(.system(size: 16))
                    .foregroundStyle(Pika.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            VStack(spacing: 10) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(PillButtonStyle())
                Button("Not now") { finish(startBook: false) }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Pika.inkSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .transition(.opacity)
    }

    // MARK: scanning (fast: last 60 days)

    private var scanning: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(Pika.bgSoft, lineWidth: 10)
                    .frame(width: 132, height: 132)
                Circle()
                    .trim(from: 0, to: max(0.03, scanner.progress))
                    .stroke(Pika.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .frame(width: 132, height: 132)
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.5, dampingFraction: 0.9), value: scanner.progress)
                Image(systemName: "person.crop.square.badge.camera")
                    .font(.system(size: 40))
                    .foregroundStyle(Pika.accent)
            }
            Spacer().frame(height: 32)
            VStack(spacing: 12) {
                Text("Finding the people\nin your photos")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Pika.ink)
                    .multilineTextAlignment(.center)
                Text(scanner.statusText.isEmpty ? "Looking through your recent photos…" : scanner.statusText)
                    .font(.system(size: 15))
                    .foregroundStyle(Pika.inkSecondary)
                    .contentTransition(.numericText())
                if limitedAccess {
                    Text("You granted access to selected photos only. Pikabook works, but books get better with full library access (Settings › Pikabook).")
                        .font(.system(size: 13))
                        .foregroundStyle(Pika.inkSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                        .padding(.top, 4)
                }
            }
            Spacer()
        }
        .transition(.opacity)
        .task {
            guard !scanner.scanning else { return }
            await scanner.scan(daysBack: 60)
            preselectTopPeople()
            step = .people
        }
    }

    /// Star the three most-photographed people so the pick screen starts with
    /// a sensible default.
    private func preselectTopPeople() {
        let store = PeopleStore.shared
        guard !store.clusters.contains(where: { $0.role == .required }) else { return }
        let top = store.clusters.sorted { $0.count > $1.count }.prefix(3).map(\.id)
        for i in store.clusters.indices where top.contains(store.clusters[i].id) {
            store.clusters[i].role = .required
        }
        store.save()
    }

    // MARK: people pick

    private var people: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Who should every\nbook include?")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Pika.ink)
                    .multilineTextAlignment(.center)
                    .padding(.top, 28)
                Text("Every photo we pick will include at least one selected person. Tap to change who's in. Names are optional; add them anytime in the People tab.")
                    .font(.system(size: 15))
                    .foregroundStyle(Pika.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            OnboardingPeopleGrid()
                .padding(.top, 20)
            VStack(spacing: 10) {
                Button("Make my first book") { finish(startBook: true) }
                    .buttonStyle(PillButtonStyle())
                Button("Skip for now") { finish(startBook: true) }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Pika.inkSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .transition(.opacity)
    }

    private func finish(startBook: Bool) {
        PeopleStore.shared.save()
        OnboardingState.done = true
        if startBook {
            let cal = Calendar.current
            let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
            if let lastMonth = cal.date(byAdding: .month, value: -1, to: thisMonth),
               monthPhotoCount(lastMonth) >= 8 {
                CreateCoordinator.shared.start(month: lastMonth)
            }
            // Tiny library: land on the gallery quietly; the FAB explains itself.
        }
        finished()
    }

    private func monthPhotoCount(_ month: Date) -> Int {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return 0 }
        let cal = Calendar.current
        guard let end = cal.date(byAdding: .month, value: 1, to: month) else { return 0 }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                                     month as NSDate, end as NSDate)
        return PHAsset.fetchAssets(with: .image, options: opts).count
    }
}

/// Onboarding people pick: the 10 most-photographed faces, top 3 pre-starred.
/// Tap toggles "every book includes them". Small name affordance under each
/// tile; naming is optional.
private struct OnboardingPeopleGrid: View {
    @ObservedObject var store = PeopleStore.shared
    @State private var naming: PersonCluster?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        Group {
            if store.clusters.isEmpty {
                VStack(spacing: 6) {
                    Text("No faces found yet")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Pika.ink)
                    Text("That's okay. Pikabook still makes books, and it keeps learning as photos arrive.")
                        .font(.system(size: 14))
                        .foregroundStyle(Pika.inkSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(top10) { cluster in
                            tile(cluster)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                }
            }
        }
        .sheet(item: $naming) { cluster in
            OnboardingNameSheet(clusterID: cluster.id)
                .presentationDetents([.height(250)])
                .presentationCornerRadius(Pika.sheetRadius)
        }
    }

    private var top10: [PersonCluster] {
        Array(store.clusters.sorted { $0.count > $1.count }.prefix(10))
    }

    private func toggle(_ cluster: PersonCluster) {
        guard let i = store.clusters.firstIndex(where: { $0.id == cluster.id }) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            store.clusters[i].role = store.clusters[i].role == .required ? .neutral : .required
            store.save()
        }
    }

    private func tile(_ cluster: PersonCluster) -> some View {
        let selected = cluster.role == .required
        return VStack(spacing: 6) {
            Button { toggle(cluster) } label: {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let data = cluster.repCropPNG, let img = UIImage(data: data) {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            Pika.bgSoft.overlay(
                                Image(systemName: "person.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(Pika.inkSecondary))
                        }
                    }
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(selected ? Pika.accent : .clear, lineWidth: 3)
                    )
                    .opacity(selected ? 1 : 0.72)
                    .pikaShadow()

                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(selected ? Pika.accent : .white.opacity(0.9))
                        .background(Circle().fill(.white.opacity(selected ? 1 : 0.25)).padding(2))
                        .padding(6)
                }
            }
            .buttonStyle(PressCardStyle())

            Button { naming = cluster } label: {
                Text(cluster.name.isEmpty ? "Add name" : cluster.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(cluster.name.isEmpty ? Pika.inkSecondary : Pika.ink)
                    .lineLimit(1)
            }
        }
    }
}

/// Minimal name-only sheet for the onboarding grid.
private struct OnboardingNameSheet: View {
    let clusterID: PersonCluster.ID
    @ObservedObject var store = PeopleStore.shared
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    private var idx: Int? { store.clusters.firstIndex { $0.id == clusterID } }

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(Pika.hairline).frame(width: 36, height: 4).padding(.top, 10)
            if let idx {
                if let data = store.clusters[idx].repCropPNG, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                        .pikaShadow()
                }
                TextField("Name", text: Binding(
                    get: { store.clusters[idx].name },
                    set: { store.clusters[idx].name = $0 }
                ))
                .font(.system(size: 17, weight: .medium))
                .multilineTextAlignment(.center)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Pika.bgSoft))
                .padding(.horizontal, 40)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { store.save(); dismiss() }
                .onAppear { nameFocused = true }

                Button("Done") {
                    store.save()
                    dismiss()
                }
                .buttonStyle(PillButtonStyle())
                .padding(.horizontal, 40)
            }
            Spacer(minLength: 12)
        }
        .background(Pika.bg)
    }
}
