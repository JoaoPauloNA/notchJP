import SwiftUI

enum PanelTabs {
    static let orderKey = "njp.tabs.order"
    static let hiddenKey = "njp.tabs.hidden"
    static let openingKey = "njp.tabs.opening"
    static var titles: [String] { ["Spotify", AppLanguage.text("Cotas e saldos"), AppLanguage.text("Calendário"), "Mac", AppLanguage.text("Agentes"), AppLanguage.text("Ferramentas"), AppLanguage.text("Áudio")] }
    static let symbols = ["music.note", "chart.bar.fill", "calendar", "cpu", "terminal", "square.grid.2x2", "slider.horizontal.3"]
    // Existing numeric identities remain stable; positions are stored separately.
    static func normalized(_ values: [Int]) -> [Int] {
        var result: [Int] = []
        for id in values + Array(0..<NJPSettings.pageCount) where (0..<NJPSettings.pageCount).contains(id) && !result.contains(id) { result.append(id) }
        return result
    }
    static var order: [Int] { normalized((UserDefaults.standard.array(forKey: orderKey) as? [Int]) ?? []) }
    static var visible: [Int] {
        let hidden = UserDefaults.standard.array(forKey: hiddenKey) as? [Int] ?? []
        let result = order.filter { !hidden.contains($0) }
        return result.isEmpty ? [0] : result
    }
}

struct PanelTabsSettings: View {
    @State private var revision = 0
    @AppStorage(PanelTabs.openingKey) private var opening = 0

    private func update(_ action: () -> Void) {
        action(); revision += 1
        if !PanelTabs.visible.contains(opening) { opening = PanelTabs.visible[0] }
        NotificationCenter.default.post(name: .njpSettingsChanged, object: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLanguage.text("Abas do painel")).font(.headline)
            ForEach(PanelTabs.order, id: \.self) { id in
                HStack {
                    Toggle(PanelTabs.titles[id], isOn: Binding(get: { PanelTabs.visible.contains(id) }, set: { show in
                        update {
                            var hidden = UserDefaults.standard.array(forKey: PanelTabs.hiddenKey) as? [Int] ?? []
                            if show { hidden.removeAll { $0 == id } }
                            else if PanelTabs.visible.count > 1 { hidden.append(id) }
                            UserDefaults.standard.set(hidden, forKey: PanelTabs.hiddenKey)
                        }
                    }))
                    Spacer()
                    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).padding(6)
                        .draggable(String(id)).help(AppLanguage.text("Arraste para ordenar"))

                }
                .dropDestination(for: String.self) { items, _ in
                    guard let text = items.first, let source = Int(text), source != id,
                          PanelTabs.order.contains(source) else { return false }
                    update {
                        var order = PanelTabs.order.filter { $0 != source }
                        let index = order.firstIndex(of: id) ?? order.count
                        order.insert(source, at: index)
                        UserDefaults.standard.set(order, forKey: PanelTabs.orderKey)
                    }
                    return true
                }
            }
            Picker(AppLanguage.text("Aba inicial"), selection: $opening) {
                ForEach(PanelTabs.visible, id: \.self) { id in Text(PanelTabs.titles[id]).tag(id) }
            }
            Text(AppLanguage.text("A aba inicial é usada quando “Lembrar a última aba” está desligado.")).font(.caption).foregroundStyle(.secondary)
            Button(AppLanguage.text("Restaurar abas padrão")) {
                update {
                    for key in [PanelTabs.orderKey, PanelTabs.hiddenKey, PanelTabs.openingKey] { UserDefaults.standard.removeObject(forKey: key) }
                    opening = 0
                }
            }
        }.id(revision)
    }

    private func move(_ id: Int, by delta: Int) {
        update {
            var order = PanelTabs.order
            guard let index = order.firstIndex(of: id), order.indices.contains(index + delta) else { return }
            order.swapAt(index, index + delta)
            UserDefaults.standard.set(order, forKey: PanelTabs.orderKey)
        }
    }
}
