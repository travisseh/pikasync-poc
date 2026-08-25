import SwiftUI

/// "Who is this book about" — photo-forward grid of discovered people.
/// Tap a face to name them, star them (book must feature), or exclude them.
/// Persisted and applied to every generation.
struct PeoplePickerView: View {
    @ObservedObject var scanner: PeopleScanner
    @ObservedObject var store = PeopleStore.shared
    @State private var editing: PersonCluster?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if scanner.scanning {
                    VStack(spacing: 8) {
                        ProgressView(value: scanner.progress).tint(Pika.accent)
                        Text(scanner.statusText)
                            .font(.system(size: 13))
                            .foregroundStyle(Pika.inkSecondary)
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: Pika.cardRadius).fill(Pika.bgSoft))
                }

                if store.clusters.isEmpty && !scanner.scanning {
                    VStack(spacing: 8) {
                        Text("No people yet")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Pika.ink)
                        Text("Scan your photos and the faces Pikabook finds will appear here.")
                            .font(.system(size: 15))
                            .foregroundStyle(Pika.inkSecondary)
                            .multilineTextAlignment(.center)
                        Button("Scan my photos") { Task { await scanner.scan() } }
                            .buttonStyle(PillButtonStyle())
                            .padding(.top, 8)
                    }
                    .padding(.vertical, 48)
                    .padding(.horizontal, 24)
                } else if !store.clusters.isEmpty {
                    Text("★ they're who books are about · ⃠ never include")
                        .font(.system(size: 13))
                        .foregroundStyle(Pika.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(sorted) { cluster in
                            Button { editing = cluster } label: {
                                FaceTile(cluster: cluster)
                            }
                            .buttonStyle(PressCardStyle())
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Pika.bg)
        .navigationTitle("People")
        .toolbar {
            Button(scanner.scanning ? "Scanning…" : "Rescan") {
                Task { await scanner.scan() }
            }
            .disabled(scanner.scanning)
        }
        .sheet(item: $editing) { cluster in
            PersonSheet(clusterID: cluster.id)
                .presentationDetents([.height(360)])
                .presentationCornerRadius(Pika.sheetRadius)
        }
        .onDisappear { store.save() }
    }

    private var sorted: [PersonCluster] {
        store.clusters.sorted { $0.count > $1.count }
    }
}

private struct FaceTile: View {
    let cluster: PersonCluster

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let data = cluster.repCropPNG, let img = UIImage(data: data) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Pika.bgSoft.overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(Pika.inkSecondary)
                        )
                    }
                }
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .pikaShadow()

                if cluster.role != .neutral {
                    Image(systemName: cluster.role == .required ? "star.fill" : "nosign")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(cluster.role == .required ? Pika.accent : Pika.inkSecondary)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(5)
                }
            }
            VStack(spacing: 1) {
                Text(cluster.name.isEmpty ? "Unnamed" : cluster.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(cluster.name.isEmpty ? Pika.inkSecondary : Pika.ink)
                    .lineLimit(1)
                Text("\(cluster.count) photos")
                    .font(.system(size: 12))
                    .foregroundStyle(Pika.inkSecondary)
            }
        }
    }
}

/// Bottom sheet: rename, set role, or remove a person cluster.
private struct PersonSheet: View {
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
                        .frame(width: 88, height: 88)
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

                HStack(spacing: 10) {
                    roleChip("Star", icon: "star.fill", role: .required, idx: idx)
                    roleChip("Neutral", icon: "circle", role: .neutral, idx: idx)
                    roleChip("Exclude", icon: "nosign", role: .excluded, idx: idx)
                }
                .padding(.horizontal, 20)

                Button("Remove this person") {
                    store.clusters.remove(at: idx)
                    store.save()
                    dismiss()
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.red)
                .padding(.top, 4)
            }
            Spacer(minLength: 12)
        }
        .background(Pika.bg)
        .onDisappear { store.save() }
    }

    @ViewBuilder
    private func roleChip(_ label: String, icon: String, role: PersonCluster.Role, idx: Int) -> some View {
        let selected = store.clusters[idx].role == role
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                store.clusters[idx].role = role
                store.save()
            }
        } label: {
            Label(label, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? .white : Pika.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Capsule().fill(selected ? Pika.accent : Pika.bgSoft))
        }
    }
}
