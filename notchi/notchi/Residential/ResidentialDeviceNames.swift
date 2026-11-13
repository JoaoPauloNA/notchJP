import SwiftUI
import Combine

/// Local display names keyed by provider and stable device identity, never by network address.
@MainActor final class ResidentialDeviceNames: ObservableObject {
    // Avoid Swift isolated-deinit back-deployment crashes (swiftlang/swift#88036).
    nonisolated deinit {}
    static let shared = ResidentialDeviceNames()
    private static let key = "njp.residential.deviceNames"
    private let defaults: UserDefaults
    @Published var isEditing = false
    @Published private var names: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        names = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func name(for id: String, fallback: String) -> String { names[id] ?? fallback }

    func rename(_ id: String, to value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        names[id] = trimmed.isEmpty ? nil : trimmed
        defaults.set(names, forKey: Self.key)
    }
}

struct ResidentialDeviceNameEditor: View {
    let originalName: String
    let save: (String) -> Void
    @State private var draft: String
    @Environment(\.dismiss) private var dismiss

    init(name: String, originalName: String, save: @escaping (String) -> Void) {
        self.originalName = originalName
        self.save = save
        _draft = State(initialValue: name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nome do aparelho").font(.headline)
            TextField("Ex.: sala ou quarto", text: $draft)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Nome do aparelho no notchJP")
                .onSubmit { commit() }
            Text("Este nome aparece apenas no notchJP deste Mac.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Usar nome original") { save(""); dismiss() }
                    .help(originalName)
                Spacer()
                Button("Cancelar") { dismiss() }
                Button("Salvar") { commit() }.buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(18).frame(width: 350)
    }

    private func commit() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        save(draft)
        dismiss()
    }
}

struct ResidentialRenameButton: View {
    let name: String
    let originalName: String
    let save: (String) -> Void
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            Image(systemName: "pencil").frame(width: 24, height: 24).contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .help("Renomear \(name)")
            .accessibilityLabel("Renomear \(name)")
            .onChange(of: editing) { _, value in ResidentialDeviceNames.shared.isEditing = value }
            .onDisappear { ResidentialDeviceNames.shared.isEditing = false }
            .popover(isPresented: $editing) {
                ResidentialDeviceNameEditor(name: name, originalName: originalName, save: save)
            }
    }
}
