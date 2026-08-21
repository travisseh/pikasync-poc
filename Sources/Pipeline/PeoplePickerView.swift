import SwiftUI

/// "Who is this book about" — name the discovered people, star the ones the
/// book must feature, exclude the ones it must never include. Persisted and
/// applied to every generation.
struct PeoplePickerView: View {
    @ObservedObject var store = PeopleStore.shared

    var body: some View {
        List {
            if store.clusters.isEmpty {
                Text("No people discovered yet. Run the pipeline once and faces will appear here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sorted) { cluster in
                row(cluster)
            }
        }
        .navigationTitle("People")
        .onDisappear { store.save() }
    }

    private var sorted: [PersonCluster] {
        store.clusters.sorted { $0.count > $1.count }
    }

    @ViewBuilder
    private func row(_ cluster: PersonCluster) -> some View {
        let idx = store.clusters.firstIndex { $0.id == cluster.id }
        HStack(spacing: 12) {
            if let data = cluster.repCropPNG, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable().scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
            } else {
                Circle().fill(.gray.opacity(0.3)).frame(width: 56, height: 56)
                    .overlay(Image(systemName: "person.fill").foregroundStyle(.gray))
            }
            VStack(alignment: .leading, spacing: 4) {
                if let idx {
                    TextField("Name", text: Binding(
                        get: { store.clusters[idx].name },
                        set: { store.clusters[idx].name = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Text("\(cluster.count) faces").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let idx {
                Picker("", selection: Binding(
                    get: { store.clusters[idx].role },
                    set: { store.clusters[idx].role = $0; store.save() }
                )) {
                    Image(systemName: "star.fill").tag(PersonCluster.Role.required)
                    Image(systemName: "circle").tag(PersonCluster.Role.neutral)
                    Image(systemName: "nosign").tag(PersonCluster.Role.excluded)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }
        }
    }
}
