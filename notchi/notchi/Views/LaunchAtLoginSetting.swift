import AppKit
import ServiceManagement
import SwiftUI

struct LaunchAtLoginSetting: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Abrir o notchJP ao iniciar sessão", isOn: Binding(get: { status == .enabled }, set: { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    error = nil
                } catch { self.error = error.localizedDescription }
                status = SMAppService.mainApp.status
            }))
            .toggleStyle(.switch)
            Text("Abre automaticamente quando você entra no macOS.")
                .font(.caption).foregroundStyle(.secondary)
            if status == .requiresApproval {
                Button("Autorizar nos Itens de Início do macOS") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(18)
        .background(NJP.surface, in: RoundedRectangle(cornerRadius: 22))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
        }
    }
}
