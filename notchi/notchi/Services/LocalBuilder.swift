import AppKit
import Foundation

/// "Recompilar e instalar": builds this project with Xcode, swaps /Applications/notchJP.app and reopens it.
/// The work runs in a detached shell so it survives the app quitting itself.
enum LocalBuilder {
    static let repoKey = "njp.repoPath"
    private static let buildScript = "scripts/build-local-app.sh"

    static func validRepo(_ path: String?) -> String? {
        guard let path, FileManager.default.isExecutableFile(atPath: path + "/" + buildScript) else { return nil }
        return path
    }

    /// Remembered folder, or the usual location, or nil.
    static func storedRepo() -> String? {
        validRepo(UserDefaults.standard.string(forKey: repoKey))
    }

    @MainActor
    static func confirmAndRun() {
        var repo = storedRepo()
        if repo == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.message = "Escolha a pasta do projeto notchJP (a que tem scripts/build-local-app.sh)"
            panel.prompt = "Usar esta pasta"
            guard panel.runModal() == .OK, let chosen = validRepo(panel.url?.path) else {
                let alert = NSAlert()
                alert.messageText = "Pasta inválida"
                alert.informativeText = "Não encontrei scripts/build-local-app.sh nessa pasta."
                alert.runModal()
                return
            }
            repo = chosen
        }
        guard let repo else { return }
        UserDefaults.standard.set(repo, forKey: repoKey)

        let alert = NSAlert()
        alert.messageText = "Recompilar e instalar o notchJP?"
        alert.informativeText = "O Xcode compila o projeto em \(repo). Ao terminar, o app é fechado, trocado em /Applications e reaberto. Leva alguns minutos; o andamento fica em ~/Library/Caches/Notchi/rebuild.log."
        alert.addButton(withTitle: "Recompilar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        launch(repo: repo)
    }

    static func script(repo: String) -> String {
        let build = "$HOME/Library/Caches/Notchi/Build/Build/Products/Release/notchJP.app"
        return """
        cd \(shellQuote(repo)) && NOTCH_DERIVED_DATA="$HOME/Library/Caches/Notchi/Build" ./scripts/build-local-app.sh && \
        /usr/bin/python3 scripts/install-local-app.py "\(build)" --destination /Applications/notchJP.app
        """
    }

    private static func launch(repo: String) {
        let log = NSHomeDirectory() + "/Library/Caches/Notchi/rebuild.log"
        try? FileManager.default.createDirectory(atPath: (log as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup /bin/zsh -c \(shellQuote(script(repo: repo))) > '\(log)' 2>&1 &"]
        try? process.run()
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
