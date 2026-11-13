import AppKit
import Foundation

/// Quit and restart for an app that has no Dock icon or menu bar item.
enum AppControl {
    /// Shell that waits for this process to leave, then opens the app again.
    static func restartScript(bundlePath: String, pid: Int32) -> String {
        let quoted = "'" + bundlePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \(quoted)"
    }

    @MainActor
    static func restart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup /bin/sh -c " + shellQuote(restartScript(bundlePath: Bundle.main.bundlePath,
                                                                                    pid: ProcessInfo.processInfo.processIdentifier)) + " >/dev/null 2>&1 &"]
        try? process.run()
        NSApp.terminate(nil)
    }

    @MainActor
    static func quit() { NSApp.terminate(nil) }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
