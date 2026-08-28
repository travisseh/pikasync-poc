import SwiftUI
import UIKit

/// In-list book creation: the FAB opens a "Create Photobook" sheet; Create
/// inserts a loading entry at the top of the Books list and runs the pipeline
/// behind it. Tapping the entry shows live pipeline detail; failures keep the
/// entry with a retry.
@MainActor
final class CreateCoordinator: ObservableObject {
    static let shared = CreateCoordinator()

    @MainActor
    final class Build: ObservableObject, Identifiable {
        let id = UUID()
        let month: Date
        let monthLabel: String
        @Published var runner: PipelineRunner

        init(month: Date) {
            self.month = month
            self.monthLabel = month.formatted(.dateTime.month(.wide).year())
            self.runner = PipelineRunner()
        }
    }

    @Published var builds: [Build] = []

    func start(month: Date) {
        // One build per month at a time.
        guard !builds.contains(where: { $0.month == month && $0.runner.errorText == nil }) else { return }
        let build = Build(month: month)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            builds.insert(build, at: 0)
        }
        run(build)
    }

    func retry(_ build: Build) {
        build.runner = PipelineRunner()
        run(build)
    }

    func dismiss(_ build: Build) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            builds.removeAll { $0.id == build.id }
        }
    }

    private func run(_ build: Build) {
        UIApplication.shared.isIdleTimerDisabled = true  // keep the screen awake while building
        Task { @MainActor in
            await build.runner.run(month: build.month)
            if build.runner.errorText == nil {
                // Saved run is already in RunStore — the cover card replaces
                // the loading entry.
                self.dismiss(build)
            }
            self.updateIdleTimer()
        }
    }

    /// If a persisted interactive judge job exists (app was suspended or
    /// killed mid-judge), surface it as a resuming build and poll it to
    /// completion. Called on launch and on every return to foreground.
    func resumeIfNeeded() {
        guard let state = InteractiveBuildState.load(),
              builds.allSatisfy({ !$0.runner.running }),
              let month = state.month else { return }
        let build = Build(month: month)
        build.runner.status = "Claude is choosing your photos…"
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            builds.insert(build, at: 0)
        }
        UIApplication.shared.isIdleTimerDisabled = true
        Task { @MainActor in
            await build.runner.resume(state: state)
            if build.runner.errorText == nil {
                self.dismiss(build)
            }
            self.updateIdleTimer()
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = builds.contains { $0.runner.running }
    }
}

// MARK: - FAB

struct CreateFAB: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Pika.accent))
                .pikaShadow()
        }
        .buttonStyle(PressCardStyle())
    }
}

// MARK: - Create sheet

struct CreateSheet: View {
    @ObservedObject private var coordinator = CreateCoordinator.shared
    @Environment(\.dismiss) private var dismiss

    private static var options: [Date] {
        let cal = Calendar.current
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        return (1...12).compactMap { cal.date(byAdding: .month, value: -$0, to: thisMonth) }
    }
    private let monthOptions = CreateSheet.options
    @State private var month = CreateSheet.options[0]

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(Pika.hairline).frame(width: 36, height: 4).padding(.top, 10)
            Text("Create Photobook")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Pika.ink)
                .padding(.top, 4)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(monthOptions, id: \.self) { m in
                        let selected = m == month
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { month = m }
                        } label: {
                            Text(m.formatted(.dateTime.month(.wide).year()))
                                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Pika.accent : Pika.ink)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(selected ? Pika.accent.opacity(0.1) : Pika.bgSoft)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(selected ? Pika.accent : .clear, lineWidth: 1.5)
                                )
                        }
                    }
                }
                .padding(.horizontal, 20)
            }

            Button("Create") {
                coordinator.start(month: month)
                dismiss()
            }
            .buttonStyle(PillButtonStyle())
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .background(Pika.bg)
        .presentationDetents([.height(420)])
        .presentationCornerRadius(Pika.sheetRadius)
    }
}

// MARK: - Loading / failed entry in the Books list

struct BuildingCard: View {
    @ObservedObject var build: CreateCoordinator.Build
    @ObservedObject var runner: PipelineRunner

    init(build: CreateCoordinator.Build) {
        self.build = build
        self.runner = build.runner
    }

    private var failed: Bool { runner.errorText != nil }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: Pika.cardRadius)
                .fill(Pika.bgSoft)
                .frame(height: 148)
                .overlay(alignment: .topTrailing) {
                    if failed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Pika.accent)
                            .padding(14)
                    }
                }
                .overlay {
                    if !failed { Shimmer().clipShape(RoundedRectangle(cornerRadius: Pika.cardRadius)) }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(build.monthLabel)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Pika.ink)
                if failed {
                    Text("Couldn't make this book. Tap for details")
                        .font(.system(size: 14))
                        .foregroundStyle(Pika.inkSecondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().tint(Pika.accent).scaleEffect(0.8)
                        Text(runner.status)
                            .font(.system(size: 14))
                            .foregroundStyle(Pika.inkSecondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
            }
            .padding(18)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: runner.status)
    }
}

/// Soft moving highlight for the loading card.
struct Shimmer: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(stops: [
                .init(color: .white.opacity(0), location: 0.35),
                .init(color: .white.opacity(0.6), location: 0.5),
                .init(color: .white.opacity(0), location: 0.65),
            ], startPoint: .leading, endPoint: .trailing)
            .frame(width: geo.size.width * 1.6)
            .offset(x: phase * geo.size.width * 1.6)
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Live pipeline detail sheet (loading entry tap, and "…" menu on done books)

struct BuildProgressSheet: View {
    @ObservedObject var build: CreateCoordinator.Build
    @ObservedObject var runner: PipelineRunner
    @Environment(\.dismiss) private var dismiss

    init(build: CreateCoordinator.Build) {
        self.build = build
        self.runner = build.runner
    }

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(Pika.hairline).frame(width: 36, height: 4).padding(.top, 10)
            Text(build.monthLabel)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Pika.ink)

            if let err = runner.errorText {
                ScrollView {
                    Text(err)
                        .font(.system(size: 14))
                        .foregroundStyle(Pika.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Pika.bgSoft))
                        .padding(.horizontal, 20)

                    stageList
                }
                Button("Try again") {
                    CreateCoordinator.shared.retry(build)
                    dismiss()
                }
                .buttonStyle(PillButtonStyle())
                .padding(.horizontal, 20)
                Button("Remove") {
                    CreateCoordinator.shared.dismiss(build)
                    dismiss()
                }
                .buttonStyle(PillButtonStyle(filled: false))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            } else {
                HStack(spacing: 8) {
                    ProgressView().tint(Pika.accent)
                    Text(runner.status)
                        .font(.system(size: 14))
                        .foregroundStyle(Pika.inkSecondary)
                }
                ScrollView { stageList }
            }
            Spacer(minLength: 8)
        }
        .background(Pika.bg)
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(Pika.sheetRadius)
    }

    private var stageList: some View {
        StageListView(stages: runner.stageTimes.map {
            SavedRun.Stage(name: $0.name, detail: $0.detail, seconds: $0.seconds)
        }, judgeInfo: runner.judgeInfo)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

/// Shared dev-progress list: live during a build, persisted on saved books.
struct StageListView: View {
    let stages: [SavedRun.Stage]
    var judgeInfo: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(stages.enumerated()), id: \.offset) { _, st in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(st.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Pika.ink)
                        Spacer()
                        Text(String(format: "%.1fs", st.seconds))
                            .font(.system(size: 13))
                            .foregroundStyle(Pika.inkSecondary)
                    }
                    Text(st.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Pika.inkSecondary)
                }
            }
            if !stages.isEmpty {
                HStack {
                    Text("Total").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pika.ink)
                    Spacer()
                    Text(String(format: "%.1fs", stages.reduce(0) { $0 + $1.seconds }))
                        .font(.system(size: 13)).foregroundStyle(Pika.inkSecondary)
                }
            }
            if !judgeInfo.isEmpty {
                Text(judgeInfo)
                    .font(.system(size: 12))
                    .foregroundStyle(Pika.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
