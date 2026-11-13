import SwiftUI

struct ACAccountSettingsView: View {
    @ObservedObject var controller: ACController
    @State private var authorizationError: String?
    @State private var email = ""
    @State private var password = ""
    @State private var emailCode = ""
    @State private var loginMethod = "code"
    @State private var codeSent = false
    @State private var region = "BR"
    var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Controle do ar").font(.title2.weight(.semibold))
                    .task { await controller.refreshDevices() }
                Text(controller.backend.name).foregroundStyle(.secondary)
                if let tcl = controller.backend as? TCLBackend, tcl.loginStorageNotice != nil {
                    Text(tcl.loginStorageNotice ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let tcl = controller.backend as? TCLBackend {
                    Button("Autorizar sessão salva no Chaveiro") {
                        do { try tcl.authorizeSavedSession(); Task { await controller.refresh() } }
                        catch { authorizationError = error.localizedDescription }
                    }
                    if let authorizationError { Text(authorizationError).font(.caption).foregroundStyle(.orange) }
                }
                if !controller.devices.isEmpty {
                    Picker("Aparelho", selection: Binding(get: { controller.selectedDeviceID ?? "" }, set: { id in
                        controller.select(id)
                    })) {
                        ForEach(controller.devices) { device in
                            Text(controller.displayName(for: device) + (device.online ? "" : " · desconectado")).tag(device.id)
                        }
                    }.disabled(controller.busy)
                    if controller.selectedDeviceID != nil {
                        HStack {
                            Text(controller.selectedDisplayName).lineLimit(1)
                            ResidentialRenameButton(name: controller.selectedDisplayName, originalName: controller.originalSelectedName) {
                                controller.renameSelected(to: $0)
                            }.id(controller.selectedDeviceID)
                        }
                    }
                    Text("\(controller.devices.count) aparelho\(controller.devices.count > 1 ? "s" : "") na conta. No painel, o seletor do topo troca entre eles.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Acesso com conta TCL").font(.headline)
                Picker("Entrar com", selection: $loginMethod) {
                    Text("Código por e-mail").tag("code")
                    Text("Senha TCL").tag("password")
                }.pickerStyle(.segmented).disabled(controller.busy)
                TextField("E-mail da conta TCL Home", text: $email)
                    .textContentType(.username).autocorrectionDisabled()
                HStack {
                    Text("País da conta").font(.callout)
                    Spacer()
                    TextField("BR", text: $region).frame(width: 65)
                }
                if loginMethod == "code" {
                    Text("Use o mesmo e-mail vinculado à sua conta TCL Home, inclusive se você entra pelo Google.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(controller.busy ? "Aguarde…" : codeSent ? "Solicitar outro código" : "Solicitar código por e-mail") {
                        Task { codeSent = await controller.requestLoginCode(email: email.trimmingCharacters(in: .whitespacesAndNewlines), region: region.uppercased()) }
                    }.disabled(controller.busy || email.isEmpty || region.isEmpty)
                    if codeSent { Text("Código solicitado. Confira sua caixa de entrada e o spam.").font(.caption).foregroundStyle(.secondary) }
                    TextField("Código recebido por e-mail", text: $emailCode)
                        .textContentType(.oneTimeCode).autocorrectionDisabled()
                } else {
                    SecureField("Senha TCL Home", text: $password).textContentType(.password)
                    Text("Use uma senha própria da TCL Home. A senha do Google não deve ser usada aqui.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(controller.busy ? "Conectando…" : "Conectar") {
                    Task {
                        let accountEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
                        let connected: Bool
                        if loginMethod == "code" {
                            connected = await controller.signInWithCode(email: accountEmail, code: emailCode.trimmingCharacters(in: .whitespacesAndNewlines), region: region.uppercased())
                        } else {
                            connected = await controller.signIn(email: accountEmail, password: password, region: region.uppercased())
                        }
                        if connected {
                            password = ""
                            emailCode = ""
                        }
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(controller.busy || email.isEmpty || (loginMethod == "code" ? emailCode.isEmpty : password.isEmpty) || region.isEmpty)
                if let error = controller.error {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                if let updated = controller.lastUpdated { Text("Última atualização: \(updated.formatted(date: .omitted, time: .standard))").font(.caption) }
                Text("Os controles ficam disponíveis depois de obter o estado do aparelho.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Menu("Mais") {
                        Button("Sair da conta TCL") { controller.signOut(); password = ""; emailCode = ""; codeSent = false }.disabled(controller.busy)
                    }.fixedSize()
                    Spacer()
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }
}
