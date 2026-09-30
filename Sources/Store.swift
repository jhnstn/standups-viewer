import Foundation
import SwiftUI

struct Standup: Identifiable, Hashable {
    let id: String          // "2026-09-24"
    let date: Date
    let url: URL
    var dayLabel: String {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f.string(from: date)
    }
}

struct Period: Identifiable {
    let id: Int
    let start: Date
    let end: Date
    var items: [Standup]
    var label: String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        let y = DateFormatter(); y.dateFormat = "yyyy"
        let thisYear = y.string(from: Date())
        let suffix = y.string(from: start) == thisYear ? "" : ", \(y.string(from: start))"
        return "\(f.string(from: start)) – \(f.string(from: end))\(suffix)"
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var periods: [Period] = []
    @Published var selectedID: String? { didSet { loadSelected() } }
    @Published var markdown: String = ""
    @Published var frontmatter: [String: String] = [:]
    @Published var hasToday = false
    /// Today's date as a file stem ("2026-09-28"). Published so the sidebar's "today" tag and the
    /// Generate button both move over when the day changes while the app stays open.
    @Published private(set) var today: String = Store.dayFormatter.string(from: Date())
    @Published var isGenerating = false
    @Published var statusText = ""
    @Published var errorText: String?

    let dir: URL
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var process: Process?
    private var outputBuffer = Data()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f
    }()

    init() {
        // Override with: defaults write com.jhnstn.standups StandupsDirectory "/path/to/folder"
        if let custom = UserDefaults.standard.string(forKey: "StandupsDirectory"), !custom.isEmpty {
            dir = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects/standups")
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
        watch()
        watchForNewDay()
    }

    var todayID: String { today }

    // MARK: day rollover

    private var dayObservers: [NSObjectProtocol] = []
    private var dayTimer: Timer?

    /// The date can change while the app is open (midnight) or while the Mac sleeps (wake the next
    /// morning). Any of these signals re-checks it; the timer is a backstop if a notification is missed.
    private func watchForNewDay() {
        let check: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForNewDay() }
        }
        dayObservers = [
            NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: check),
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: check),
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: check),
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: check),
        ]
        dayTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForNewDay() }
        }
    }

    func checkForNewDay() {
        let now = Store.dayFormatter.string(from: Date())
        guard now != today else { return }
        today = now
        reload()
    }

    func reload() {
        today = Store.dayFormatter.string(from: Date())
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var standups: [Standup] = []
        for f in files where f.pathExtension == "md" {
            let name = f.deletingPathExtension().lastPathComponent
            guard let d = Store.dayFormatter.date(from: name) else { continue }
            standups.append(Standup(id: name, date: d, url: f))
        }
        standups.sort { $0.date > $1.date }
        hasToday = standups.contains { $0.id == todayID }

        // Two-week buckets anchored on a Monday (2024-01-01), so the groups line up with weeks.
        var cal = Calendar.current; cal.firstWeekday = 2
        let anchor = Store.dayFormatter.date(from: "2024-01-01")!
        var buckets: [Int: Period] = [:]
        for s in standups {
            let days = cal.dateComponents([.day], from: anchor, to: cal.startOfDay(for: s.date)).day ?? 0
            let idx = Int((Double(days) / 14.0).rounded(.down))
            if buckets[idx] == nil {
                let start = cal.date(byAdding: .day, value: idx * 14, to: anchor)!
                let end = cal.date(byAdding: .day, value: 13, to: start)!
                buckets[idx] = Period(id: idx, start: start, end: end, items: [])
            }
            buckets[idx]!.items.append(s)
        }
        periods = buckets.values.sorted { $0.id > $1.id }

        if let sel = selectedID, standups.contains(where: { $0.id == sel }) {
            loadSelected()
        } else {
            selectedID = standups.first?.id
        }
    }

    func loadSelected() {
        guard let id = selectedID, let s = periods.flatMap(\.items).first(where: { $0.id == id }),
              let text = try? String(contentsOf: s.url, encoding: .utf8) else {
            markdown = ""; frontmatter = [:]; return
        }
        let (fm, body) = Store.splitFrontmatter(text)
        frontmatter = fm
        markdown = body
    }

    /// Flips the Nth task-list checkbox (counted like the renderer: document order, outside code
    /// fences, frontmatter excluded) in the selected report and saves it. Returns the new body.
    func toggleTask(index: Int, checked: Bool) -> String? {
        guard let id = selectedID, let s = periods.flatMap(\.items).first(where: { $0.id == id }),
              let text = try? String(contentsOf: s.url, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        var start = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            start = close + 1
        }
        let task = try! NSRegularExpression(pattern: #"^(\s*(?:[-*+]|\d+[.)])\s+\[)([ xX])(\])"#)
        var inFence = false, seen = 0
        for i in start..<lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            let ns = line as NSString
            guard let m = task.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            if seen == index {
                lines[i] = ns.replacingCharacters(in: m.range(at: 2), with: checked ? "x" : " ")
                let updated = lines.joined(separator: "\n")
                do { try updated.write(to: s.url, atomically: true, encoding: .utf8) } catch { return nil }
                let body = Store.splitFrontmatter(updated).1
                markdown = body
                return body
            }
            seen += 1
        }
        return nil
    }

    /// Splits a leading `---` block into key/value pairs and returns the rest.
    static func splitFrontmatter(_ text: String) -> ([String: String], String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], text)
        }
        var fm: [String: String] = [:]
        for line in lines[1..<close] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fm[key] = value
        }
        return (fm, lines[(close + 1)...].joined(separator: "\n"))
    }

    // MARK: directory watching

    private func watch() {
        fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            // Writers often touch the file more than once; coalesce.
            NSObject.cancelPreviousPerformRequests(withTarget: self as Any)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.reload() }
        }
        src.setCancelHandler { [fd = self.fd] in close(fd) }
        src.resume()
        source = src
    }

    // MARK: generation

    /// Runs the standup skill headlessly. `claude` resolves through the login shell so ~/.local/bin is on PATH.
    /// Generates today's report, or, when it already exists, updates it with today's progress.
    func generate() {
        guard !isGenerating else { return }
        let updating = hasToday
        let todayURL = dir.appendingPathComponent("\(todayID).md")
        let before = (try? todayURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        isGenerating = true
        errorText = nil
        statusText = updating ? "Updating today's standup…" : "Generating today's standup…"
        outputBuffer = Data()

        // Extra tools your skill needs (MCP servers etc.) come from a local preference:
        //   defaults write com.jhnstn.standups ExtraAllowedTools -array "mcp__server__tool" ...
        let extra = UserDefaults.standard.stringArray(forKey: "ExtraAllowedTools") ?? []
        let tools = (["Bash", "Read", "Write", "Edit", "Glob", "Grep", "Skill", "ToolSearch", "Agent"] + extra)
            .joined(separator: ",")
        let prompt = updating ? "/standup update" : "/standup"
        guard let env = Store.shellEnvironment(), let claude = Store.findClaude(path: env["PATH"] ?? "") else {
            isGenerating = false
            statusText = "claude not found"
            errorText = """
            Could not find the claude CLI. The app looked on the PATH your shell sets up \
            (zsh -lic), then in ~/.local/bin, /opt/homebrew/bin and /usr/local/bin.

            If it lives somewhere else, point the app at it:
            defaults write com.jhnstn.standups ClaudePath /full/path/to/claude
            """
            return
        }

        let p = Process()
        p.executableURL = claude
        // default mode: exactly the allowlisted tools run, with no auto-mode classifier in the loop.
        p.arguments = ["-p", prompt, "--permission-mode", "default", "--allowedTools", tools, "--output-format", "text"]
        p.environment = env
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice   // claude -p otherwise waits 3s for stdin
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            DispatchQueue.main.async { self?.outputBuffer.append(d) }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.isGenerating = false
                self.process = nil
                self.reload()
                let output = String(data: self.outputBuffer, encoding: .utf8) ?? ""
                if proc.terminationStatus != 0 {
                    self.errorText = "claude exited with status \(proc.terminationStatus).\n\n\(output.suffix(4000))"
                    self.statusText = "Generation failed"
                } else if !self.hasToday {
                    self.errorText = "claude finished but no file appeared at \(self.dir.path)/\(self.todayID).md.\n\n\(output.suffix(4000))"
                    self.statusText = "No standup written"
                } else {
                    let after = (try? todayURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    let f = DateFormatter(); f.dateFormat = "h:mm a"
                    if updating && after == before {
                        self.statusText = "No new work since the last update"
                    } else {
                        self.statusText = (updating ? "Updated at " : "Generated at ") + f.string(from: Date())
                    }
                    self.selectedID = self.todayID
                    self.loadSelected()
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            isGenerating = false
            errorText = "Could not start claude: \(error.localizedDescription)"
        }
    }

    /// The environment an interactive login zsh ends up with, so PATH includes whatever
    /// ~/.zshrc adds (apps launched from Finder only get a minimal PATH). Cached after first use.
    private static var cachedEnv: [String: String]?
    static func shellEnvironment() -> [String: String]? {
        if let cachedEnv { return cachedEnv }
        var env = ProcessInfo.processInfo.environment
        let marker = "__STANDUPS_PATH__"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -i so .zshrc runs; the marker separates PATH from anything the rc files print.
        p.arguments = ["-lic", "print -r -- \(marker)$PATH\(marker)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let deadline = Date().addingTimeInterval(10)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { p.terminate() }
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let parts = text.components(separatedBy: marker)
            if parts.count >= 3, !parts[1].isEmpty { env["PATH"] = parts[1] }
        }
        // Belt and braces: make sure the common tool locations are present either way.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for e in extras where !path.contains(e) { path.append(e) }
        env["PATH"] = path.joined(separator: ":")
        cachedEnv = env
        return env
    }

    static func findClaude(path: String) -> URL? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: "ClaudePath"), !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/claude"
            if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    func cancelGeneration() {
        process?.terminate()
        statusText = "Cancelled"
    }

    func revealInFinder() {
        let target = periods.flatMap(\.items).first { $0.id == selectedID }?.url ?? dir
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}
