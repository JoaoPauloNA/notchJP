import AppKit
import Darwin

/// Brings the terminal that hosts an agent process to the front (and the right iTerm tab).
enum TerminalFocus {
    /// Parent of `pid`, or nil when it is gone or is launchd.
    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    /// First ancestor that is a regular GUI application (the terminal window owner).
    static func hostApplication(of pid: pid_t, maxDepth: Int = 14) -> NSRunningApplication? {
        var current: pid_t? = pid
        var depth = 0
        while let candidate = current, depth < maxDepth {
            if let app = NSRunningApplication(processIdentifier: candidate), app.activationPolicy == .regular {
                return app
            }
            current = parentPID(of: candidate)
            depth += 1
        }
        return nil
    }

    @discardableResult
    static func activate(processId: Int?) -> Bool {
        guard let processId, let app = hostApplication(of: pid_t(processId)) else { return false }
        app.activate(options: [.activateAllWindows])
        if app.bundleIdentifier == "com.googlecode.iterm2", let tty = ttyName(of: pid_t(processId)) {
            selectITermSession(tty: tty)
        }
        return true
    }

    static func ttyName(of pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return normalizedTTY(String(data: data, encoding: .utf8) ?? "")
    }

    /// "ttys003\n" -> "ttys003"; "??" or empty -> nil.
    static func normalizedTTY(_ raw: String) -> String? {
        let tty = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tty.isEmpty, tty != "??", tty.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return tty
    }

    private static func selectITermSession(tty: String) {
        let source = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (tty of s) ends with "\(tty)" then
                            select t
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }
}
