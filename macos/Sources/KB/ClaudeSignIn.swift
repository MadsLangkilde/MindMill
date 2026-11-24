import AppKit
import KBCore
import KBEngine
import Observation
import SwiftUI

/// Signing Claude Code in again from the app, when a session fails because its login is missing, expired
/// or refused: `claude auth login` opens the browser, and once it's done the failed sessions restart on the
/// new login and send their last message again.
@MainActor
@Observable
final class ClaudeSignIn {
    enum Phase: Equatable {
        /// Asking `claude auth status` whether Claude Code is signed in.
        case checking
        case signedIn(String)
        case signedOut
        /// `claude auth login` is waiting for the browser.
        case waiting
        case done(String)
        case failed(String)
    }

    /// Why sign-in is needed, from the last failure; the banner shows while it is set.
    var problem: String?
    var showSheet = false
    var phase: Phase = .checking
    /// The page `claude auth login` printed, for when the browser didn't open.
    var url: URL?

    /// Chats whose last turn failed to sign in.
    @ObservationIgnored let failedChats = NSHashTable<ClaudeChat>.weakObjects()
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var output = ""

    var isWaiting: Bool { phase == .waiting }

    func cancel() {
        process?.terminate()
        process = nil
        if phase == .waiting { phase = .signedOut }
    }

    /// Runs `claude auth status --json` off the main thread.
    static func status(claude: URL, environment: [String: String]) async -> ClaudeAuth.Status? {
        await Task.detached {
            let p = Process()
            p.executableURL = claude
            p.arguments = ["auth", "status", "--json"]
            p.environment = environment
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return ClaudeAuth.Status.decode(String(decoding: data, as: UTF8.self))
        }.value
    }

    /// Starts `claude auth login`, which opens the browser and exits once the user has signed in.
    func login(claude: URL, environment: [String: String], finished: @escaping @MainActor (ClaudeAuth.Status?) -> Void) {
        cancel()
        output = ""
        url = nil
        phase = .waiting
        let p = Process()
        p.executableURL = claude
        p.arguments = ["auth", "login"]
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = Pipe()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.output += chunk
                if self.url == nil { self.url = ClaudeAuth.signInURL(in: self.output) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            let reason = proc.terminationReason
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                self.process = nil
                Task { @MainActor in
                    let status = await Self.status(claude: claude, environment: environment)
                    if status?.loggedIn == true, code == 0 || ClaudeAuth.succeeded(self.output) {
                        self.phase = .done(status?.account ?? "")
                    } else if reason == .uncaughtSignal {
                        self.phase = .signedOut
                    } else {
                        let text = ClaudeAuth.plainText(self.output).trimmingCharacters(in: .whitespacesAndNewlines)
                        self.phase = .failed(text.isEmpty ? "claude auth login stopped with code \(code)." : String(text.suffix(400)))
                    }
                    finished(status)
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            phase = .failed("Could not run claude auth login: \(error.localizedDescription)")
        }
    }
}

extension AppModel {
    /// Called from every Claude chat's stream: remembers the chat and puts up the banner.
    func wireClaudeSignIn() {
        ClaudeChat.onSignInProblem = { [weak self] chat, text in
            // Not from inside the stream handler's observation pass (see startBackgroundWork).
            DispatchQueue.main.async {
                guard let self else { return }
                self.claudeSignIn.failedChats.add(chat)
                self.claudeSignIn.problem = ClaudeAuth.shortReason(text)
            }
        }
    }

    func openClaudeSignIn() {
        claudeSignIn.showSheet = true
        checkClaudeSignIn()
    }

    func checkClaudeSignIn() {
        guard case .found(let exe) = claudeAvailability else {
            claudeSignIn.phase = .failed(claudeMissingExplanation)
            return
        }
        claudeSignIn.phase = .checking
        let env = claudeEnvironment()
        Task {
            let status = await ClaudeSignIn.status(claude: exe, environment: env)
            guard claudeSignIn.phase == .checking else { return }
            claudeSignIn.phase = status?.loggedIn == true ? .signedIn(status?.account ?? "") : .signedOut
        }
    }

    func startClaudeLogin() {
        guard case .found(let exe) = claudeAvailability else {
            claudeSignIn.phase = .failed(claudeMissingExplanation)
            return
        }
        claudeSignIn.login(claude: exe, environment: claudeEnvironment()) { [weak self] status in
            if status?.loggedIn == true { self?.resumeAfterSignIn() }
        }
    }

    /// Opens Terminal on `claude auth login`, for when signing in from the app doesn't work.
    func claudeLoginInTerminal() {
        guard case .found(let exe) = claudeAvailability else {
            errorMessage = claudeMissingExplanation
            return
        }
        claudeSignIn.cancel()
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/zsh -il
        clear
        echo "Sign in to Claude for Mindmill. When it says Login successful, go back to Mindmill and press Check Again."
        echo
        \(quote(exe.path)) auth login
        """
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("KB")
        let url = dir.appendingPathComponent("claude-login.command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            errorMessage = "Could not write \(url.path): \(error.localizedDescription)"
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// The failed chats stop their processes, which still hold the old login, and each session sends the
    /// message that failed again; that starts a fresh process continuing the same conversation.
    func resumeAfterSignIn() {
        let retry = sessions.filter { $0.chat.needsSignIn && $0.chat.lastShown != nil }
        for chat in claudeSignIn.failedChats.allObjects { chat.signedInAgain() }
        for s in sessions where s.chat.needsSignIn { s.chat.signedInAgain() }
        claudeSignIn.failedChats.removeAllObjects()
        claudeSignIn.problem = nil
        for s in retry {
            guard let last = s.chat.lastShown else { continue }
            s.chat.items.append(.init(role: .status, text: "Signed in again. Sending your last message again."))
            send(last.text, in: s, display: last.display, attachments: last.attachments, listed: true)
        }
        notice = retry.isEmpty ? "Claude is signed in again."
            : "Claude is signed in again. \(retry.count) session\(retry.count == 1 ? "" : "s") sent the failed message again."
    }
}

/// Across the top of the window while a Claude session has failed to sign in.
struct ClaudeSignInBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let problem = model.claudeSignIn.problem {
            AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 200) {
                Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude needs you to sign in again").fontWeight(.semibold)
                    Text(problem).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button("Not Now") { model.claudeSignIn.problem = nil }
                    Button("Sign In…") { model.openClaudeSignIn() }
                        .buttonStyle(.borderedProminent)
                }
                .fixedSize()
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

/// Signs Claude Code in through the browser, the way `/login` does in the terminal.
struct ClaudeSignInSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let signIn = model.claudeSignIn
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key.fill").font(.title2).foregroundStyle(Color.accentColor)
                Text("Sign in to Claude").font(.title2.weight(.semibold))
            }
            if let problem = signIn.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content(signIn)
            Divider()
            HStack(spacing: 10) {
                if signIn.phase != .checking, !isDone(signIn.phase) {
                    Button("Use Terminal Instead") { model.claudeLoginInTerminal() }
                        .help("Runs claude auth login in Terminal. Come back and press Check Again when it's done.")
                    Button("Check Again") { model.checkClaudeSignIn() }
                        .disabled(signIn.isWaiting)
                }
                Spacer()
                Button(isDone(signIn.phase) ? "Done" : "Cancel") {
                    signIn.cancel()
                    signIn.showSheet = false
                }
                .keyboardShortcut(isDone(signIn.phase) ? .defaultAction : .cancelAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func isDone(_ phase: ClaudeSignIn.Phase) -> Bool {
        if case .done = phase { return true }
        return false
    }

    @ViewBuilder
    private func content(_ signIn: ClaudeSignIn) -> some View {
        switch signIn.phase {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking Claude's sign-in…").foregroundStyle(.secondary)
            }
        case .signedIn(let account):
            Text("Claude Code is signed in\(account.isEmpty ? "" : " as \(account)"), but the sessions that failed still use the login they started with. Restarting them picks up the current one.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Restart Sessions") {
                    model.resumeAfterSignIn()
                    signIn.phase = .done(account)
                }
                .buttonStyle(.borderedProminent)
                Button("Sign In Again in the Browser") { model.startClaudeLogin() }
            }
            Text("If it fails again with a Cloudflare page, the network is being blocked: try without the VPN, or another connection.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .signedOut:
            Text("Claude Code isn't signed in. Your browser opens on the Claude sign-in page; sign in there and come back.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Sign In in the Browser") { model.startClaudeLogin() }
                .buttonStyle(.borderedProminent)
        case .waiting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finish signing in in your browser. Mindmill carries on by itself when you're done.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = signIn.url {
                HStack(spacing: 10) {
                    Text("Browser didn't open?").foregroundStyle(.secondary)
                    Button("Open the Sign-In Page") { NSWorkspace.shared.open(url) }
                    CopyButton(label: "Copy Link", text: url.absoluteString)
                }
                .font(.callout)
            }
        case .done(let account):
            Label("Signed in\(account.isEmpty ? "" : " as \(account)"). The sessions that failed are running again.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label("Signing in didn't finish.", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { model.startClaudeLogin() }
                .buttonStyle(.borderedProminent)
        }
    }
}
