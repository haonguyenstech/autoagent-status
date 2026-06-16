import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Paths & constants

let cliCandidates = [
    "/opt/homebrew/bin/auto-agent-ai",
    "/usr/local/bin/auto-agent-ai",
]
let home = FileManager.default.homeDirectoryForCurrentUser.path
let agentHome = ProcessInfo.processInfo.environment["AUTO_AGENT_AI_HOME"] ?? "\(home)/.auto-agent-ai"
let statePath = "\(agentHome)/state.json"
let logPath = "\(agentHome)/watch.log"
let keychainService = "Claude Code-credentials"
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
let updateRepo = "haonguyenstech/autoagent-status" // private repo with release zips
let installedAppPath = "\(home)/Applications/AutoAgent Status.app"

/// Read-only fine-grained PAT (Contents: read on the update repo only),
/// injected at build time from .update-token — see build.sh. Nil when absent.
var updateToken: String? {
    guard let d = Data(base64Encoded: updateTokenB64), !d.isEmpty,
          let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !s.isEmpty else { return nil }
    return s
}

// MARK: - Shell helpers

struct CommandResult {
    let code: Int32
    let output: String
}

/// `onOutput` is called on a background queue with the full accumulated output
/// each time a chunk arrives; return `true` from it to abort the process early
/// (used to bail out of an interactive sign-in we can't complete unattended).
@discardableResult
func runCommand(_ path: String, _ args: [String], timeout: TimeInterval = 30,
                onOutput: ((String) -> Bool)? = nil) -> CommandResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    proc.standardInput = FileHandle.nullDevice
    // Apps launched from Finder get a minimal PATH; the CLI needs node.
    // Include the resolved CLI's own bin dir (covers nvm/volta/asdf installs).
    var env = ProcessInfo.processInfo.environment
    var extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
    if let cli = cachedCLIPath {
        extraPaths.insert((cli as NSString).deletingLastPathComponent, at: 0)
    }
    env["PATH"] = extraPaths.joined(separator: ":") + ":" + (env["PATH"] ?? "/usr/bin:/bin")
    proc.environment = env
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe

    var data = Data()
    let lock = NSLock()
    var aborted = false
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if !chunk.isEmpty {
            lock.lock()
            data.append(chunk)
            let snapshot = String(data: data, encoding: .utf8) ?? ""
            lock.unlock()
            if let onOutput, !aborted, onOutput(snapshot) {
                aborted = true
                proc.terminate()
            }
        }
    }

    do { try proc.run() } catch {
        return CommandResult(code: -1, output: "Failed to launch \(path): \(error.localizedDescription)")
    }

    let deadline = Date().addingTimeInterval(timeout)
    while proc.isRunning && Date() < deadline { usleep(50_000) }
    var timedOut = false
    if proc.isRunning {
        timedOut = true
        proc.terminate()
        usleep(300_000)
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
    }
    proc.waitUntilExit()
    usleep(50_000) // let the readability handler drain
    pipe.fileHandleForReading.readabilityHandler = nil

    lock.lock()
    let text = String(data: data, encoding: .utf8) ?? ""
    lock.unlock()
    let suffix = timedOut ? "\n[timed out after \(Int(timeout))s]" : ""
    return CommandResult(code: timedOut ? -2 : proc.terminationStatus,
                         output: text.trimmingCharacters(in: .whitespacesAndNewlines) + suffix)
}

func stripANSI(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
}

/// The CLI hard-blocks with an "Update required" box when the installed
/// version is below the server's minimum — it exits non-zero and refuses to
/// run (login/push/logout/watcher) until it's npm-updated. Detect that so we
/// can prompt (or auto-update) instead of dumping the raw box as a failure.
func isUpdateRequired(_ output: String) -> Bool {
    let s = stripANSI(output).lowercased()
    return s.contains("update required")
        || s.contains("required update")
        || s.contains("can no longer be used")
}

/// `login` now does interactive Microsoft OAuth: it prints a sign-in URL and
/// waits for the browser callback. Pull that URL out of the CLI's output so we
/// can re-open it / show it as a fallback (the CLI tries to open it itself).
func extractLoginURL(_ output: String) -> String? {
    let clean = stripANSI(output)
    guard let re = try? NSRegularExpression(pattern: "https?://[^\\s\"'`)]+") else { return nil }
    let ns = clean as NSString
    let urls = re.matches(in: clean, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }
    // Prefer the CLI auth redirect (has cli_redirect/cli_state) over any other link.
    return urls.first { $0.contains("cli_redirect") || $0.contains("cli_state") }
        ?? urls.first { $0.contains("/login") }
}

let defaultServer = "https://vibe.saigontechnology.vn"
let npmCandidates = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
let cliPackage = "@saigontechnology/auto-agent"

var cachedCLIPath: String?

/// Find the CLI: known locations first, then ask the user's login shell —
/// that picks up nvm / volta / asdf installs whose bin dirs aren't fixed.
func findCLI() -> String? {
    let fm = FileManager.default
    if let c = cachedCLIPath, fm.isExecutableFile(atPath: c) { return c }
    for p in cliCandidates where fm.isExecutableFile(atPath: p) {
        cachedCLIPath = p
        return p
    }
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let r = runCommand(shell, ["-l", "-i", "-c", "command -v auto-agent-ai"], timeout: 10)
    if let path = r.output.split(separator: "\n").map(String.init)
        .last(where: { $0.hasPrefix("/") }),
       fm.isExecutableFile(atPath: path) {
        cachedCLIPath = path
        return path
    }
    return nil
}

var npmPath: String? {
    var candidates = npmCandidates
    if let cli = cachedCLIPath {
        // npm usually lives next to the CLI (same node bin dir)
        candidates.insert((cli as NSString).deletingLastPathComponent + "/npm", at: 0)
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Any HTTP response (even 403/404) means the server is reachable.
func pingServer(_ urlString: String) -> (ok: Bool, ms: Int) {
    guard let url = URL(string: urlString) else { return (false, 0) }
    var req = URLRequest(url: url)
    req.httpMethod = "HEAD"
    req.timeoutInterval = 4
    var ok = false
    let start = Date()
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, resp, _ in
        ok = resp != nil
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 5)
    return (ok, Int(Date().timeIntervalSince(start) * 1000))
}

/// Resolve the CLI symlink and read version from its package.json (no subprocess).
func installedCLIVersion() -> String? {
    let fm = FileManager.default
    let candidates = (cachedCLIPath.map { [$0] } ?? []) + cliCandidates
    for cli in candidates where fm.fileExists(atPath: cli) {
        var resolved = (try? fm.destinationOfSymbolicLink(atPath: cli)) ?? cli
        if !resolved.hasPrefix("/") {
            resolved = ((cli as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent(resolved)
        }
        let pkgDir = ((resolved as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let pkg = ((pkgDir as NSString).appendingPathComponent("package.json") as NSString).standardizingPath
        if let d = fm.contents(atPath: pkg),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let v = obj["version"] as? String {
            return v
        }
    }
    return nil
}

/// Latest app release from the GitHub repo (works for the private repo via
/// the embedded read-only token; the asset API URL is used for download).
func fetchLatestAppRelease() -> (version: String, zipURL: String)? {
    guard let url = URL(string: "https://api.github.com/repos/\(updateRepo)/releases/latest") else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 10
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    if let t = updateToken {
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
    }
    var result: (String, String)?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, _ in
        defer { sem.signal() }
        guard let data,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return }
        let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = obj["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let dl = zip["url"] as? String else { return } // asset API URL, not browser_download_url
        result = (ver, dl)
    }.resume()
    _ = sem.wait(timeout: .now() + 12)
    return result.map { (version: $0.0, zipURL: $0.1) }
}

func isNewer(_ a: String, than b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}

// MARK: - Token usage (same algorithm as the CLI: scan today's Claude
// Code transcripts in ~/.claude/projects/**/*.jsonl, dedupe by message id)

struct TokenUsage {
    var input = 0
    var output = 0
    var cacheCreate = 0
    var cacheRead = 0
    var billable: Int { input + output + cacheCreate }
    var total: Int { billable + cacheRead }
}

func formatTokens(_ n: Int) -> String {
    let d = Double(n)
    func fmt(_ v: Double) -> String {
        v >= 100 ? String(format: "%.1f", v) : String(format: "%.2f", v)
    }
    if d >= 1_000_000 { return fmt(d / 1_000_000) + "M" }
    if d >= 1_000 { return String(format: "%.1fK", d / 1_000) }
    return "\(n)"
}

func readTokenUsage() -> TokenUsage {
    var u = TokenUsage()
    let fm = FileManager.default

    var configDirs = ["\(home)/.claude"]
    if let cfg = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
        configDirs.append(cfg)
    }

    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    let today = df.string(from: Date())
    // skip files untouched since well before today (26 h, like the CLI)
    let cutoff = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-26 * 3600)

    let isoFrac = ISO8601DateFormatter()
    isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let iso = ISO8601DateFormatter()

    var seen = Set<String>()
    for dir in configDirs {
        let projects = dir + "/projects"
        guard let en = fm.enumerator(atPath: projects) else { continue }
        for case let rel as String in en {
            guard rel.hasSuffix(".jsonl") else { continue }
            let path = projects + "/" + rel
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date, mtime >= cutoff,
                  let data = fm.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard line.contains("\"usage\""),
                      let d = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { continue }
                if let ts = obj["timestamp"] as? String {
                    guard let date = isoFrac.date(from: ts) ?? iso.date(from: ts),
                          df.string(from: date) == today else { continue }
                }
                if let mid = msg["id"] as? String {
                    let key = mid + "\u{0}" + ((obj["requestId"] as? String) ?? "")
                    if seen.contains(key) { continue }
                    seen.insert(key)
                }
                u.input += usage["input_tokens"] as? Int ?? 0
                u.output += usage["output_tokens"] as? Int ?? 0
                u.cacheCreate += usage["cache_creation_input_tokens"] as? Int ?? 0
                u.cacheRead += usage["cache_read_input_tokens"] as? Int ?? 0
            }
        }
    }
    return u
}

func notify(_ title: String, _ body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
}

// MARK: - Status model

struct AgentStatus {
    var watcherRunning = false
    var watcherPid: Int?
    var credentialPresent = false
    var expiresAt: Date?
    var role: String?
    var username: String?
    var serverUrl: String?
    var lastLogLine: String?
    var serverOK: Bool?
    var serverLatencyMs: Int?

    var credentialValid: Bool {
        guard let e = expiresAt else { return false }
        return e > Date()
    }

    enum State { case active, warning, inactive }

    var state: State {
        if watcherRunning && credentialValid { return .active }
        if watcherRunning || credentialPresent { return .warning }
        return .inactive
    }

    var headline: String {
        switch (watcherRunning, credentialValid, credentialPresent) {
        case (true, true, _): return "Credential synced and watching"
        case (true, false, true): return "Credential expired — watcher syncing"
        case (true, false, false): return "Watcher running — waiting for credential"
        case (false, _, true): return "Watcher stopped — credential present"
        default: return "Logged out"
        }
    }

    var stateLabel: String {
        switch state {
        case .active: return "Active"
        case .warning: return "Attention"
        case .inactive: return "Offline"
        }
    }

    var color: Color {
        switch state {
        case .active: return .green
        case .warning: return .orange
        case .inactive: return .gray
        }
    }

    var symbolName: String {
        switch state {
        case .active: return "key.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .inactive: return "key.slash"
        }
    }
}

func readStatus() -> AgentStatus {
    var s = AgentStatus()

    // 1. Background watcher process
    let pg = runCommand("/usr/bin/pgrep", ["-f", "auto-agent-ai __watch"], timeout: 5)
    if pg.code == 0, let first = pg.output.split(separator: "\n").first, let pid = Int(first) {
        s.watcherRunning = true
        s.watcherPid = pid
    }

    // 2. Local state written by the CLI
    if let d = FileManager.default.contents(atPath: statePath),
       let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
        s.role = obj["role"] as? String
        s.username = obj["username"] as? String
        s.serverUrl = obj["serverUrl"] as? String
    }

    // 3. Server reachability
    let ping = pingServer(s.serverUrl ?? defaultServer)
    s.serverOK = ping.ok
    s.serverLatencyMs = ping.ok ? ping.ms : nil

    // 4. Keychain credential + expiry
    let exists = runCommand("/usr/bin/security", ["find-generic-password", "-s", keychainService], timeout: 5)
    if exists.code == 0 {
        s.credentialPresent = true
        let secret = runCommand("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-w"], timeout: 5)
        if secret.code == 0,
           let d = secret.output.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let oauth = obj["claudeAiOauth"] as? [String: Any] {
            if let ms = oauth["expiresAt"] as? Double {
                s.expiresAt = Date(timeIntervalSince1970: ms / 1000)
            } else if let ms = oauth["expiresAt"] as? Int {
                s.expiresAt = Date(timeIntervalSince1970: Double(ms) / 1000)
            }
        }
    }

    // 5. Last watcher log line (tail ~4 KB)
    if let fh = FileHandle(forReadingAtPath: logPath) {
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > 4096 ? size - 4096 : 0
        try? fh.seek(toOffset: start)
        if let d = try? fh.readToEnd(), let text = String(data: d, encoding: .utf8) {
            s.lastLogLine = text.split(separator: "\n").map(String.init)
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        }
    }

    return s
}

// MARK: - Store

final class StatusStore: ObservableObject {
    @Published var status = AgentStatus()
    @Published var busy: String?
    @Published var lastError: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var autoRestart = UserDefaults.standard.object(forKey: "autoRestart") as? Bool ?? true
    @Published var installedVersion: String?
    @Published var latestVersion: String?
    @Published var updatingCLI = false
    @Published var autoUpdateCLI = UserDefaults.standard.object(forKey: "autoUpdateCLI") as? Bool ?? true
    @Published var usage: TokenUsage?
    @Published var appLatestVersion: String?
    @Published var appDownloadURL: String?
    @Published var updatingApp = false
    /// CLI returned the "Update required" hard-block — it can't run until updated.
    @Published var cliUpdateRequired = false
    /// Microsoft sign-in URL while an interactive login is waiting on the browser.
    @Published var loginURL: String?

    private let workQueue = DispatchQueue(label: "auto-agent-status.work")
    private let usageQueue = DispatchQueue(label: "auto-agent-status.usage", qos: .utility)
    private var lastVersionCheck = Date.distantPast
    private var lastUsageScan = Date.distantPast
    private var hasStatus = false
    private var lastUserAction = Date.distantPast
    private var lastAutoRestartAt = Date.distantPast

    /// Last role we logged in with — survives the CLI wiping state.json,
    /// so auto-restart knows what to log back in as.
    private var savedRole: String? {
        get { UserDefaults.standard.string(forKey: "lastRole") }
        set { UserDefaults.standard.set(newValue, forKey: "lastRole") }
    }

    @Published var cliPath: String?

    func refresh() {
        workQueue.async {
            let cli = findCLI()
            let s = readStatus()
            DispatchQueue.main.async {
                self.cliPath = cli
                self.apply(s)
            }
        }
        checkVersions()
        refreshUsage()
    }

    /// Scan today's Claude transcripts (at most every 5 min — it reads files).
    func refreshUsage(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastUsageScan) > 300 else { return }
        lastUsageScan = Date()
        usageQueue.async {
            let u = readTokenUsage()
            DispatchQueue.main.async { self.usage = u }
        }
    }

    func setAutoUpdateCLI(_ on: Bool) {
        autoUpdateCLI = on
        UserDefaults.standard.set(on, forKey: "autoUpdateCLI")
        if on { checkVersions(force: true) }
    }

    /// Compare installed CLI version with the registry (at most every 6 h unless forced).
    func checkVersions(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastVersionCheck) > 6 * 3600 else { return }
        lastVersionCheck = Date()
        workQueue.async {
            let installed = installedCLIVersion()
            var latest: String?
            if let npm = npmPath {
                let r = runCommand(npm, ["view", cliPackage, "version"], timeout: 30)
                if r.code == 0,
                   let line = r.output.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces),
                   !line.isEmpty {
                    latest = line
                }
            }
            let appRelease = fetchLatestAppRelease()
            DispatchQueue.main.async {
                self.installedVersion = installed
                self.latestVersion = latest
                if let appRelease {
                    self.appLatestVersion = appRelease.version
                    self.appDownloadURL = appRelease.zipURL
                    if isNewer(appRelease.version, than: appVersion) {
                        notify("App update available",
                               "AutoAgent Status v\(appRelease.version) is available — click Update App in the panel.")
                    }
                }
                if let latest, let installed, isNewer(latest, than: installed) {
                    if self.autoUpdateCLI, !self.updatingCLI {
                        notify("CLI update", "Auto-updating auto-agent-ai v\(installed) → v\(latest)…")
                        self.updateCLI()
                    } else {
                        notify("CLI update available", "auto-agent-ai v\(latest) is available (you have v\(installed)).")
                    }
                }
            }
        }
    }

    func updateCLI(then completion: (() -> Void)? = nil) {
        guard !updatingCLI else { return }
        guard let npm = npmPath else {
            lastError = "npm not found in /opt/homebrew/bin or /usr/local/bin"
            return
        }
        updatingCLI = true
        lastError = nil
        workQueue.async {
            let r = runCommand(npm, ["install", "-g", "\(cliPackage)@latest"], timeout: 240)
            DispatchQueue.main.async {
                self.updatingCLI = false
                if r.code != 0 {
                    self.lastError = "CLI update failed:\n" + String(stripANSI(r.output).suffix(400))
                } else {
                    self.cliUpdateRequired = false
                    notify("CLI updated", "auto-agent-ai was updated successfully.")
                    completion?()
                }
                self.checkVersions(force: true)
            }
        }
    }

    private func apply(_ new: AgentStatus) {
        let old = hasStatus ? status : nil
        status = new
        hasStatus = true
        if let role = new.role { savedRole = role }
        if let old { notifyTransitions(old: old, new: new) }
        maybeAutoRestart(new)
    }

    private func notifyTransitions(old: AgentStatus, new: AgentStatus) {
        // Don't notify about changes the user just caused (login/logout clicks).
        let userJustActed = Date().timeIntervalSince(lastUserAction) < 20
        if old.watcherRunning && !new.watcherRunning && !userJustActed {
            notify("Watcher stopped", "The auto-agent watcher is no longer running.")
        }
        if old.credentialPresent && !new.credentialPresent && !userJustActed {
            notify("Credential removed", "The Claude Code credential was wiped from your Keychain.")
        }
        if old.credentialValid && !new.credentialValid && new.credentialPresent && !new.watcherRunning {
            notify("Token expired", "The token expired and no watcher is running to renew it.")
        }
        if old.state != .active && new.state == .active {
            notify("AutoAgent active", "Credential synced and watcher running.")
        }
    }

    /// Self-healing: if the watcher died but we know the last role, log in again.
    private func maybeAutoRestart(_ s: AgentStatus) {
        guard autoRestart, busy == nil, !s.watcherRunning else { return }
        guard let role = s.role ?? savedRole else { return }
        guard Date().timeIntervalSince(lastUserAction) > 20 else { return }
        guard Date().timeIntervalSince(lastAutoRestartAt) > 300 else { return } // retry at most every 5 min
        lastAutoRestartAt = Date()
        runCLI("auto-restart (\(role))", ["login", "--role", role], isAutoRestart: true)
    }

    func setAutoRestart(_ on: Bool) {
        autoRestart = on
        UserDefaults.standard.set(on, forKey: "autoRestart")
    }

    func login(role: String) {
        savedRole = role
        runCLI("login (\(role))", ["login", "--role", role], interactive: true)
    }
    func push() { runCLI("push", ["push"]) }
    func logout() {
        savedRole = nil // user chose to leave — disable auto-restart until next login
        runCLI("logout", ["logout"])
    }

    private func runCLI(_ name: String, _ args: [String],
                        isAutoRestart: Bool = false, isRetry: Bool = false, interactive: Bool = false) {
        guard busy == nil else { return }
        guard let cli = cliPath ?? findCLI() else {
            lastError = "auto-agent-ai CLI not found. Install it: npm install -g \(cliPackage)"
            return
        }
        busy = name
        lastError = nil
        loginURL = nil
        lastUserAction = Date()
        // Interactive sign-in waits on the browser callback, so give it room.
        let timeout: TimeInterval = interactive ? 180 : 90
        workQueue.async {
            var sawURL = false
            var abortedForAuth = false
            let result = runCommand(cli, args, timeout: timeout) { text in
                // Only logins surface a sign-in URL; ignore everything else.
                guard interactive || isAutoRestart, !sawURL, let url = extractLoginURL(text) else { return false }
                sawURL = true
                if isAutoRestart {
                    // Can't complete an interactive sign-in unattended — bail and ask the user.
                    abortedForAuth = true
                    DispatchQueue.main.async {
                        notify("Sign-in required",
                               "The watcher needs you to sign in again — open AutoAgent and click Owner or Client Login.")
                    }
                    return true // abort the hung process
                }
                DispatchQueue.main.async {
                    self.loginURL = url
                    notify("Finish signing in",
                           "Complete the Microsoft sign-in in your browser to finish logging in.")
                }
                return false // keep waiting for the browser callback
            }
            let fresh = readStatus()
            DispatchQueue.main.async {
                self.busy = nil
                self.loginURL = nil
                self.lastUserAction = Date()
                self.apply(fresh)
                if abortedForAuth { return } // user was already notified; no error banner
                if result.code != 0 {
                    if isUpdateRequired(result.output) {
                        self.cliUpdateRequired = true
                        // Auto-update once, then retry the original command.
                        if self.autoUpdateCLI, !isRetry, !self.updatingCLI {
                            notify("CLI update required",
                                   "auto-agent-ai must be updated before it can run — updating now…")
                            self.updateCLI {
                                self.runCLI(name, args, isAutoRestart: isAutoRestart,
                                            isRetry: true, interactive: interactive)
                            }
                        } else {
                            self.lastError = "auto-agent-ai requires an update before it can run. "
                                + "Click \u{201C}Update CLI now\u{201D} above."
                        }
                        return
                    }
                    self.lastError = "\(name) failed (exit \(result.code)):\n"
                        + String(stripANSI(result.output).suffix(400))
                } else {
                    self.cliUpdateRequired = false
                    if isAutoRestart {
                        notify("Watcher restarted", "Watcher was down — logged in again automatically.")
                    }
                }
                // login spawns a detached watcher that writes state shortly after
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh() }
            }
        }
    }

    /// Download the latest release zip, replace this app, and relaunch.
    func updateApp() {
        guard !updatingApp else { return }
        guard let dl = appDownloadURL else {
            lastError = "No release found yet — click Refresh first."
            return
        }
        updatingApp = true
        lastError = nil
        let auth = updateToken.map { "-H 'Authorization: Bearer \($0)'" } ?? ""
        let script = """
        set -e
        TMP=$(mktemp -d)
        /usr/bin/curl -fsSL -H 'Accept: application/octet-stream' \(auth) -o "$TMP/app.zip" '\(dl)'
        /usr/bin/ditto -x -k "$TMP/app.zip" "$TMP/x"
        SRC=$(/usr/bin/find "$TMP/x" -maxdepth 4 -name "AutoAgent Status.app" | head -1)
        test -n "$SRC"
        rm -rf '\(installedAppPath)'
        /usr/bin/ditto "$SRC" '\(installedAppPath)'
        /usr/bin/xattr -dr com.apple.quarantine '\(installedAppPath)' 2>/dev/null || true
        rm -rf "$TMP"
        """
        workQueue.async {
            let r = runCommand("/bin/bash", ["-c", script], timeout: 300)
            DispatchQueue.main.async {
                self.updatingApp = false
                if r.code != 0 {
                    self.lastError = "App update failed:\n" + String(stripANSI(r.output).suffix(400))
                    return
                }
                notify("App updated", "Restarting AutoAgent Status…")
                let relauncher = Process()
                relauncher.executableURL = URL(fileURLWithPath: "/bin/bash")
                relauncher.arguments = ["-c", "sleep 1; /usr/bin/open '\(installedAppPath)'"]
                try? relauncher.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "Start at Login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openLog() {
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        } else {
            lastError = "No log yet — log in first to start the watcher."
        }
    }
}

// MARK: - UI components

struct InfoRow: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = .primary
    var help: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.callout.weight(.medium))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(help ?? value)
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.callout.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(hovering ? 0.25 : 0.14))
            )
            .foregroundStyle(disabled ? Color.secondary : color)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Main view

struct ContentView: View {
    @ObservedObject var store: StatusStore
    @State private var confirmLogout = false

    private static let relFormatter = RelativeDateTimeFormatter()
    private static let absFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private var s: AgentStatus { store.status }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                if store.cliUpdateRequired {
                    updateRequiredBanner
                }
                if let url = store.loginURL {
                    loginBanner(url)
                }
                if let err = store.lastError {
                    errorBanner(err)
                }
                credentialCard
                usageCard
                watcherCard
                healthCard
                actionsSection
            }
            .padding(12)
            Divider()
            footer
        }
        .frame(width: 330)
        .confirmationDialog(
            "Log out of AutoAgent?",
            isPresented: $confirmLogout,
            titleVisibility: .visible
        ) {
            Button("Logout", role: .destructive) { store.logout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops the watcher and removes the Claude Code credential from your Keychain.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [s.color, s.color.opacity(0.55)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 42, height: 42)
                    .shadow(color: s.color.opacity(0.35), radius: 6, y: 2)
                Image(systemName: "key.radiowaves.forward.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("AutoAgent")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    Text("v" + appVersion)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                Text(s.headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if store.busy != nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                HStack(spacing: 5) {
                    Circle().fill(s.color).frame(width: 7, height: 7)
                    Text(s.stateLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(s.color)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(s.color.opacity(0.13), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(s.color.opacity(0.07))
    }

    // MARK: Cards

    private var roleText: String {
        guard let role = s.role else { return "Not logged in" }
        let who = s.username.map { " · \($0)" } ?? ""
        return role.capitalized + who
    }

    private var expiry: (text: String, color: Color) {
        guard let exp = s.expiresAt else {
            return (s.credentialPresent ? "Unknown" : "No credential", .secondary)
        }
        let rel = Self.relFormatter.localizedString(for: exp, relativeTo: Date())
        let abs = Self.absFormatter.string(from: exp)
        if exp <= Date() { return ("Expired \(rel)", .red) }
        if exp.timeIntervalSinceNow < 3600 { return ("\(rel) · \(abs)", .orange) }
        return ("\(rel) · \(abs)", .primary)
    }

    private var credentialCard: some View {
        Card(title: "Credential", icon: "person.badge.key.fill") {
            InfoRow(icon: "person.fill", label: "Role", value: roleText)
            InfoRow(icon: "clock.fill", label: "Token", value: expiry.text, valueColor: expiry.color)
        }
    }

    private var serverHealth: (text: String, color: Color) {
        let host = (s.serverUrl ?? defaultServer).replacingOccurrences(of: "https://", with: "")
        switch s.serverOK {
        case .some(true): return ("\(host) · \(s.serverLatencyMs ?? 0) ms", .green)
        case .some(false): return ("\(host) · unreachable", .red)
        case .none: return (host, .secondary)
        }
    }

    private var cliVersion: (text: String, color: Color) {
        guard let inst = store.installedVersion else { return ("not found", .red) }
        if let latest = store.latestVersion, isNewer(latest, than: inst) {
            return ("v\(inst) → v\(latest)", .orange)
        }
        return (store.latestVersion != nil ? "v\(inst) · up to date" : "v\(inst)", .primary)
    }

    private var updateAvailable: Bool {
        guard let inst = store.installedVersion, let latest = store.latestVersion else { return false }
        return isNewer(latest, than: inst)
    }

    private func usageCell(_ label: String, _ value: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(formatTokens(value))
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            Spacer(minLength: 0)
        }
    }

    private var usageCard: some View {
        Card(title: "Usage Today", icon: "chart.bar.fill") {
            if let u = store.usage {
                InfoRow(icon: "sum", label: "Token usage", value: formatTokens(u.billable),
                        valueColor: .blue,
                        help: "Billable = input + output + cache create (\(u.billable) tokens)")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    usageCell("Input", u.input, icon: "arrow.down", color: .teal)
                    usageCell("Output", u.output, icon: "arrow.up", color: .blue)
                    usageCell("Cache create", u.cacheCreate, icon: "plus.square.on.square", color: .purple)
                    usageCell("Cache read", u.cacheRead, icon: "bolt.fill", color: .orange)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Scanning transcripts…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var appVersionInfo: (text: String, color: Color) {
        if let latest = store.appLatestVersion, isNewer(latest, than: appVersion) {
            return ("v\(appVersion) → v\(latest)", .orange)
        }
        return (store.appLatestVersion != nil ? "v\(appVersion) · up to date" : "v\(appVersion)", .primary)
    }

    private var appUpdateAvailable: Bool {
        guard let latest = store.appLatestVersion else { return false }
        return isNewer(latest, than: appVersion)
    }

    private var healthCard: some View {
        Card(title: "Health", icon: "stethoscope") {
            InfoRow(icon: "network", label: "Server", value: serverHealth.text, valueColor: serverHealth.color)
            InfoRow(icon: "terminal.fill", label: "CLI", value: cliVersion.text, valueColor: cliVersion.color)
            InfoRow(icon: "macwindow", label: "App", value: appVersionInfo.text, valueColor: appVersionInfo.color)
            if store.updatingCLI {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Updating CLI…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if updateAvailable, let latest = store.latestVersion {
                ActionButton(title: "Update CLI to v\(latest)", icon: "arrow.down.circle.fill",
                             color: .orange) { store.updateCLI() }
            }
            if store.updatingApp {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Updating app… it will restart by itself")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if appUpdateAvailable, let latest = store.appLatestVersion {
                ActionButton(title: "Update App to v\(latest)", icon: "sparkles",
                             color: .blue) { store.updateApp() }
            }
        }
    }

    private var watcherCard: some View {
        Card(title: "Watcher", icon: "eye.fill") {
            InfoRow(
                icon: s.watcherRunning ? "checkmark.circle.fill" : "xmark.circle.fill",
                label: "Status",
                value: s.watcherRunning ? "Running · pid \(s.watcherPid ?? 0)" : "Stopped",
                valueColor: s.watcherRunning ? .green : .red
            )
            if let log = s.lastLogLine {
                Text(log)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(log)
            }
        }
    }

    // MARK: Actions

    private var actionsSection: some View {
        Group {
            if let busy = store.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Running \(busy)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ActionButton(title: "Client Login", icon: "person.fill", color: .teal,
                                 disabled: store.cliPath == nil) { store.login(role: "client") }
                    ActionButton(title: "Logout", icon: "rectangle.portrait.and.arrow.right", color: .red,
                                 disabled: store.cliPath == nil) { confirmLogout = true }
                }
            }
        }
    }

    private var updateRequiredBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("CLI update required")
                    .font(.callout.weight(.semibold))
            }
            Text("auto-agent-ai is blocked until it's updated — login, push and the watcher won't work until you update.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.updatingCLI {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Updating CLI…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ActionButton(title: "Update CLI now", icon: "arrow.down.circle.fill",
                             color: .orange) { store.updateCLI() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func loginBanner(_ url: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.shield.checkmark.fill")
                    .foregroundStyle(.blue)
                Text("Finish signing in")
                    .font(.callout.weight(.semibold))
            }
            Text("Complete the Microsoft sign-in in your browser. If it didn't open, use the button below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ActionButton(title: "Open sign-in page", icon: "safari.fill", color: .blue) {
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                }
                ActionButton(title: "Copy link", icon: "doc.on.doc.fill", color: .gray) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(4)
                .help(message)
            Spacer(minLength: 4)
            Button {
                store.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            VStack(spacing: 3) {
                SettingToggle(
                    icon: "arrow.triangle.2.circlepath", tint: .green,
                    title: "Auto-restart watcher",
                    subtitle: "Log back in if the watcher dies",
                    isOn: Binding(get: { store.autoRestart }, set: { store.setAutoRestart($0) }))
                SettingToggle(
                    icon: "arrow.down.circle.fill", tint: .orange,
                    title: "Auto-update CLI",
                    subtitle: "Install new auto-agent-ai versions",
                    isOn: Binding(get: { store.autoUpdateCLI }, set: { store.setAutoUpdateCLI($0) }))
                SettingToggle(
                    icon: "powerplug.fill", tint: .blue,
                    title: "Start at Login",
                    subtitle: "Launch automatically on sign-in",
                    isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
            }

            HStack(spacing: 10) {
                footerButton("arrow.clockwise", help: "Refresh status & check for updates") {
                    store.refresh()
                    store.checkVersions(force: true)
                    store.refreshUsage(force: true)
                }
                footerButton("doc.text", help: "Open watch log") { store.openLog() }
                Spacer()
                footerButton("power", help: "Quit AutoAgent Status") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func footerButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A polished settings row: tinted icon tile, title + subtitle, and a switch.
struct SettingToggle: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : tint)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(isOn ? 0.95 : 0.16))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.quaternary.opacity(hovering ? 0.45 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = StatusStore()
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingController(rootView: ContentView(store: store))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        store.$status.combineLatest(store.$busy)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &bag)

        store.refresh()
        store.checkVersions(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.store.refresh()
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol = store.busy != nil ? "arrow.triangle.2.circlepath" : store.status.symbolName
        let desc = store.busy ?? store.status.headline
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: desc)

        // Token countdown next to the icon, e.g. "2h 15m"
        var title = ""
        if store.busy == nil, let exp = store.status.expiresAt {
            let secs = exp.timeIntervalSinceNow
            if secs <= 0 {
                // While the watcher is renewing, the warning icon alone is enough
                title = store.status.watcherRunning ? "" : " expired"
            } else {
                let h = Int(secs) / 3600
                let m = (Int(secs) % 3600) / 60
                title = h > 0 ? " \(h)h \(m)m" : " \(m)m"
            }
        }
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)])
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeft
        if button.image == nil { button.title = "AA" }
        button.toolTip = "AutoAgent — \(desc)"
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
