import AppKit
import WebKit

/// Presents the official human challenge. Only its success callback yields a token.
@MainActor final class TCLHumanVerification: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private static var active: TCLHumanVerification?
    private var localPageURL: URL?
    private var continuation: CheckedContinuation<String, Error>?
    private var window: NSWindow?
    private var webView: WKWebView?
    private var preview = false
    private var ready = false

    static func verify() async throws -> String {
        guard active == nil else { throw failure("Uma verificação já está aberta.") }
        let verifier = TCLHumanVerification()
        active = verifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                verifier.continuation = continuation
                verifier.openWindow()
            }
        } onCancel: {
            Task { @MainActor in verifier.finish(.failure(failure("Verificação cancelada. Nenhum código foi solicitado."))) }
        }
    }

    /// Opens only the widget for runtime QA. It never calls TCL account endpoints.
    static func openPreview() {
        guard active == nil else { return }
        let verifier = TCLHumanVerification()
        verifier.preview = true
        active = verifier
        verifier.openWindow()
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "TCLHumanVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func openWindow() {
        let controller = WKUserContentController()
        controller.add(self, name: "tclHumanVerification")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = preview ? "Verificação TCL · prévia sem envio" : "Verificação de segurança TCL"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.contentView = web
        window.center()
        self.window = window
        self.webView = web
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("controle-ar-verification-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let pageURL = directory.appendingPathComponent("verification.html")
            try Self.page.write(to: pageURL, atomically: true, encoding: .utf8)
            localPageURL = pageURL
            web.loadFileURL(pageURL, allowingReadAccessTo: directory)
        } catch {
            finish(.failure(Self.failure("Não foi possível abrir a verificação visual: \(error.localizedDescription)")))
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(35))
            guard let self, !self.ready, self.window != nil else { return }
            self.finish(.failure(Self.failure("A verificação visual não carregou. Confira a conexão e tente novamente pelo botão de solicitar código.")))
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "tclHumanVerification", message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "file",
              let frameURL = message.frameInfo.request.url,
              frameURL.standardizedFileURL == localPageURL?.standardizedFileURL,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready":
            ready = true
            if preview { print("verification-widget-ready") }
        case "verified":
            guard let token = body["token"] as? String, !token.isEmpty, token.utf8.count <= 16384 else {
                finish(.failure(Self.failure("A verificação retornou uma resposta inválida. Nenhum código foi solicitado.")))
                return
            }
            finish(.success(token))
        case "cancel":
            finish(.failure(Self.failure("Verificação cancelada. Nenhum código foi solicitado.")))
        case "error":
            finish(.failure(Self.failure("Não foi possível carregar a verificação visual da TCL. Nenhum código foi solicitado. Tente novamente mais tarde.")))
        default: break
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(Self.failure("A verificação não carregou: \(error.localizedDescription)")))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The trusted document stays fixed; challenge frames may load provider content.
        if navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.navigationType != .other {
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }

    func windowWillClose(_ notification: Notification) {
        finish(.failure(Self.failure("Verificação cancelada. Nenhum código foi solicitado.")))
    }

    private func finish(_ result: Result<String, Error>) {
        guard window != nil else { return }
        let completion = continuation
        continuation = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "tclHumanVerification")
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        window?.delegate = nil
        window?.close()
        window = nil
        webView = nil
        if let localPageURL { try? FileManager.default.removeItem(at: localPageURL.deletingLastPathComponent()) }
        localPageURL = nil
        if Self.active === self { Self.active = nil }
        completion?.resume(with: result)
        if preview {
            switch result {
            case .success: print("verification-preview-completed")
            case .failure(let error): print("verification-preview-ended: \(error.localizedDescription)")
            }
            NSApplication.shared.terminate(nil)
        }
    }

    private static let page = #"""
    <!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    :root { color-scheme: dark; } body { margin:0; padding:30px; background:#111315; color:#f1f1eb; font:15px -apple-system,sans-serif; line-height:1.5; }
    h1 { font-size:21px; font-weight:600; } p { color:#b9babb; } #captcha { width:320px; margin:30px auto; min-height:42px; }
    button { color:#f1f1eb; background:#292d31; border:1px solid #555; border-radius:8px; padding:10px 18px; font:inherit; cursor:pointer; }
    #status { font-size:13px; min-height:42px; } .note { font-size:12px; }
    </style></head><body>
    <h1>Confirme que você é uma pessoa</h1>
    <p>Complete a verificação visual da TCL para solicitar o código de acesso por e-mail.</p>
    <div id="captcha"></div><p id="status">Carregando verificação…</p>
    <p class="note">O código só será solicitado depois que você concluir esta etapa.</p>
    <button id="cancel" type="button">Cancelar</button>
    <script>
    const send = (kind, token) => window.webkit.messageHandlers.tclHumanVerification.postMessage({kind:kind, token:token || ''});
    const status = document.getElementById('status');
    document.getElementById('cancel').onclick = () => send('cancel');
    function startChallenge() {
      if (typeof initNECaptcha !== 'function') { send('error'); return; }
      initNECaptcha({captchaId:'103cb918067843a6995cf3181abcda74',element:'#captcha',mode:'float',width:'320px',
        onVerify:function(err,ret) {
          if (err) { status.textContent='Não foi possível confirmar. Tente novamente na verificação acima.'; return; }
          if (ret && typeof ret.validate === 'string' && ret.validate.length) { send('verified',ret.validate); }
        }
      }, function(instance) { status.textContent='Clique na verificação acima e siga as instruções.'; send('ready'); },
      function(err) { status.textContent='Não foi possível carregar a verificação.'; send('error'); });
    }
    </script>
    <script src="https://cstaticdun.126.net/load.min.js" onload="startChallenge()" onerror="send('error')"></script>
    </body></html>
    """#
}
