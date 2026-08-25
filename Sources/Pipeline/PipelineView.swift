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
        ScrollView {
            VStack(spacing: 20) {
                // Month + run
                VStack(spacing: 14) {
                    Picker("Month", selection: $month) {
                        ForEach(monthOptions, id: \.self) { m in
                            Text(m.formatted(.dateTime.month(.wide).year())).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button(runner.running ? "Making your book…" : "Make this month's book") {
                        Task { await runner.run(month: month) }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(runner.running)
                    .opacity(runner.running ? 0.6 : 1)

                    if runner.running {
                        VStack(spacing: 6) {
                            if runner.progress > 0 {
                                ProgressView(value: runner.progress).tint(Pika.accent)
                            } else {
                                ProgressView().tint(Pika.accent)
                            }
                            Text(runner.status)
                                .font(.system(size: 13))
                                .foregroundStyle(Pika.inkSecondary)
                        }
                        .transition(.opacity)
                    }
                    if let err = runner.errorText {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: Pika.cardRadius).fill(Pika.bgSoft))

                if runner.book != nil {
                    Button {
                        showBook = true
                    } label: {
                        Label("View your book", systemImage: "book.pages")
                    }
                    .buttonStyle(PillButtonStyle(filled: false))
                }

                if !runner.stageTimes.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Behind the scenes")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Pika.ink)
                        ForEach(runner.stageTimes) { st in
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
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        HStack {
                            Text("Total").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pika.ink)
                            Spacer()
                            Text(String(format: "%.1fs", runner.stageTimes.reduce(0) { $0 + $1.seconds }))
                                .font(.system(size: 13)).foregroundStyle(Pika.inkSecondary)
                        }
                        if !runner.judgeInfo.isEmpty {
                            Text(runner.judgeInfo)
                                .font(.system(size: 12))
                                .foregroundStyle(Pika.inkSecondary)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Pika.cardRadius)
                            .fill(Color.white)
                            .overlay(RoundedRectangle(cornerRadius: Pika.cardRadius).stroke(Pika.hairline, lineWidth: 1))
                    )
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: runner.stageTimes.count)
                }

                if !runner.sheets.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(runner.sheets.enumerated()), id: \.offset) { _, img in
                                Image(uiImage: img)
                                    .resizable().scaledToFit().frame(height: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .pikaShadow()
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .padding(20)
        }
        .background(Pika.bg)
        .navigationTitle("New book")
        .navigationBarTitleDisplayMode(.inline)
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
                VStack(spacing: 20) {
                    if let img = images[book.cover_index] {
                        Image(uiImage: img).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: Pika.cardRadius))
                            .pikaShadow()
                    }
                    Text(book.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Pika.ink)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .tag(-1)

                ForEach(pages) { sel in
                    VStack(spacing: 14) {
                        if let img = images[sel.index] {
                            Image(uiImage: img).resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: Pika.cardRadius))
                                .pikaShadow()
                        } else {
                            RoundedRectangle(cornerRadius: Pika.cardRadius)
                                .fill(Pika.bgSoft)
                                .aspectRatio(4 / 3, contentMode: .fit)
                                .overlay(ProgressView())
                        }
                        Text("\(sel.page) of \(pages.count)")
                            .font(.system(size: 13))
                            .foregroundStyle(Pika.inkSecondary)
                    }
                    .padding(20)
                    .tag(sel.page)
                }
            }
            .tabViewStyle(.page)
            .background(Pika.bg)
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
