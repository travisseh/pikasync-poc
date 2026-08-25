import SwiftUI
import Photos

struct PipelineView: View {
    @StateObject private var runner = PipelineRunner()
    @State private var month = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var showBook = false

    private var monthOptions: [Date] {
        let cal = Calendar.current
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        return (1...12).compactMap { cal.date(byAdding: .month, value: -$0, to: thisMonth) }
    }

    var body: some View {
        List {
            Section("Run") {
                Picker("Month", selection: $month) {
                    ForEach(monthOptions, id: \.self) { m in
                        Text(m.formatted(.dateTime.month(.wide).year())).tag(m)
                    }
                }
                Button(runner.running ? "Running…" : "Run pipeline") {
                    Task { await runner.run(month: month) }
                }
                .disabled(runner.running)
                HStack {
                    Text("Status")
                    Spacer()
                    Text(runner.status).foregroundStyle(.secondary)
                }
                if runner.running && runner.progress > 0 {
                    ProgressView(value: runner.progress)
                }
                if let err = runner.errorText {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            if !runner.stageTimes.isEmpty {
                Section("Stage timings") {
                    ForEach(runner.stageTimes) { st in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(st.name).bold()
                                Spacer()
                                Text(String(format: "%.1fs", st.seconds)).foregroundStyle(.secondary)
                            }
                            Text(st.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Total").bold()
                        Spacer()
                        Text(String(format: "%.1fs", runner.stageTimes.reduce(0) { $0 + $1.seconds }))
                    }
                }
            }

            if !runner.sheets.isEmpty {
                Section("Contact sheets (\(runner.sheets.count))") {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(Array(runner.sheets.enumerated()), id: \.offset) { _, img in
                                Image(uiImage: img)
                                    .resizable().scaledToFit().frame(height: 220)
                                    .border(.gray.opacity(0.3))
                            }
                        }
                    }
                }
            }

            if runner.book != nil {
                Section {
                    Button("View book") { showBook = true }
                    Text(runner.judgeInfo).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Photobook pipeline")
        .sheet(isPresented: $showBook) {
            if let book = runner.book {
                BookView(book: book, shortlist: runner.shortlist, runner: runner)
            }
        }
    }
}

struct BookView: View {
    let book: BookResult
    let shortlist: [PhotoScore]
    @ObservedObject var runner: PipelineRunner
    @State private var images: [Int: UIImage] = [:]  // shortlistIndex -> full image

    private var pages: [BookSelection] { book.selections.sorted { $0.page < $1.page } }

    var body: some View {
        NavigationStack {
            TabView {
                // cover
                VStack(spacing: 16) {
                    if let img = images[book.cover_index] {
                        Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Text(book.title).font(.title).bold().multilineTextAlignment(.center)
                }
                .padding()
                .tag(-1)

                ForEach(pages) { sel in
                    VStack(spacing: 12) {
                        if let img = images[sel.index] {
                            Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            ProgressView()
                        }
                        Text("page \(sel.page)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding()
                    .tag(sel.page)
                }
            }
            .tabViewStyle(.page)
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadImages() }
        }
    }

    private func loadImages() async {
        let wanted = Set(pages.map(\.index) + [book.cover_index])
        let byIndex = Dictionary(uniqueKeysWithValues: shortlist.compactMap { s in s.shortlistIndex.map { ($0, s.id) } })
        let ids = wanted.compactMap { byIndex[$0] }
        let thumbs = await runner.loadThumbs(ids: ids, size: CGSize(width: 1600, height: 1600))
        var out: [Int: UIImage] = [:]
        for idx in wanted {
            if let id = byIndex[idx], let img = thumbs[id] { out[idx] = img }
        }
        images = out
    }
}
