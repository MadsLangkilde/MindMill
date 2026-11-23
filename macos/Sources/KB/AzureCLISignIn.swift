import AppKit
import KBCore
import Observation
import SwiftUI

/// Signing the Azure CLI in again from the app, for when the Azure DevOps tools fail because its sign-in expired
/// (AADSTS700082 after 90 days unused): `az login` opens the browser, the token check confirms it, and the sessions
/// that hit it carry on.
@MainActor
@Observable
final class AzureCLISignIn {
    enum Phase: Equatable {
        /// Asking `az` for an Azure DevOps token.
        case checking
        /// The token check passes; when the token expires.
        case working(String?)
        case signedOut(String?)
        /// `az login` is waiting for the browser.
        case waiting
        case done(String?)
        case failed(String)
    }

    /// What the session said, from the last report; the sheet shows it.
    var problem: String?
    var showSheet = false
    var phase: Phase = .checking
    /// The page `az login` printed, for when the browser didn't open.
    var url: URL?

    @ObservationIgnored let reportedChats = NSHashTable<ClaudeChat>.weakObjects()
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var output = ""

    var isWaiting: Bool { phase == .waiting }

    func cancel() {
        process?.terminate()
        process = nil
        if phase == .waiting { phase = .signedOut(nil) }
    }

    /// Runs `az` to the end off the main thread, with its output and errors together.
    nonisolated static func run(_ az: URL, _ arguments: [String], environment: [String: String]) async -> (code: Int32, output: String) {
        await Task.detached {
            let p = Process()
            p.executableURL = az
            p.arguments = arguments
            p.environment = environment
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return (-1, error.localizedDescription) }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }

    /// The token check: when the Azure DevOps token expires, or why there is none.
    nonisolated static func tokenCheck(_ az: URL, environment: [String: String]) async -> (expires: String?, reason: String?) {
        let r = await run(az, ["account", "get-access-token", "--resource", AzureSignIn.devOpsResource,
                               "--query", "expiresOn", "-o", "tsv"], environment: environment)
        if r.code == 0, let expires = AzureSignIn.expiry(r.output) { return (expires, nil) }
        return (nil, AzureSignIn.shortReason(r.output))
    }

    func check(az: URL, environment: [String: String]) {
        cancel()
        phase = .checking
        Task {
            let result = await Self.tokenCheck(az, environment: environment)
            guard phase == .checking else { return }
            phase = result.expires != nil ? .working(result.expires) : .signedOut(result.reason)
        }
    }

    /// `az login` in the account's tenant, which opens the browser and exits once the user has signed in; then the
    /// token check. `signOutFirst` runs `az logout` before, which clears every cached Azure sign-in.
    func login(az: URL, environment: [String: String], signOutFirst: Bool, finished: @escaping @MainActor (String?) -> Void) {
        cancel()
        output = ""
        url = nil
        phase = .waiting
        var env = environment
        // The subscription picker after signing in waits for a terminal that isn't there.
        env["AZURE_CORE_LOGIN_EXPERIENCE_V2"] = "off"
        Task {
            let account = await Self.run(az, ["account", "show", "--query", "tenantId", "-o", "tsv"], environment: env)
            let tenant = account.code == 0 ? account.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if signOutFirst { _ = await Self.run(az, ["logout"], environment: env) }
            guard phase == .waiting else { return }
            start(az: az, arguments: ["login"] + (tenant.isEmpty ? [] : ["--tenant", tenant]), environment: env, finished: finished)
        }
    }

    private func start(az: URL, arguments: [String], environment: [String: String], finished: @escaping @MainActor (String?) -> Void) {
        let p = Process()
        p.executableURL = az
        p.arguments = arguments
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.output += chunk
                if self.url == nil { self.url = AzureSignIn.signInURL(in: self.output) }
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
                    let check = await Self.tokenCheck(az, environment: environment)
                    if let expires = check.expires {
                        self.phase = .done(expires)
                        finished(expires)
                    } else if reason == .uncaughtSignal {
                        self.phase = .signedOut(check.reason)
                    } else {
                        let text = self.output.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.phase = .failed(check.reason ?? (text.isEmpty ? "az login stopped with code \(code)." : String(text.suffix(400))))
                    }
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            phase = .failed("Could not run az login: \(error.localizedDescription)")
        }
    }
}

extension AppModel {
    var azureCLI: URL? { AzureSignIn.executable(path: claudeEnvironment()["PATH"]) }

    private var azureMissing: String {
        "The Azure CLI (az) wasn't found on your login shell's PATH. Install it with `brew install azure-cli`, then try again."
    }

    func wireAzureSignIn() {
        ClaudeChat.onAzureSignInProblem = { [weak self] chat, text in
            DispatchQueue.main.async {
                guard let self else { return }
                self.azureSignIn.reportedChats.add(chat)
                self.azureSignIn.problem = AzureSignIn.shortReason(text)
            }
        }
    }

    func openAzureSignIn() {
        azureSignIn.showSheet = true
        checkAzureSignIn()
    }

    func checkAzureSignIn() {
        guard let az = azureCLI else {
            azureSignIn.phase = .failed(azureMissing)
            return
        }
        azureSignIn.check(az: az, environment: claudeEnvironment())
    }

    func startAzureLogin(signOutFirst: Bool = false) {
        guard let az = azureCLI else {
            azureSignIn.phase = .failed(azureMissing)
            return
        }
        azureSignIn.login(az: az, environment: claudeEnvironment(), signOutFirst: signOutFirst) { [weak self] expires in
            self?.resumeAfterAzureSignIn(expires: expires)
        }
    }

    /// Sessions waiting on the Azure sign-in.
    var sessionsWaitingOnAzure: [WorkSession] { sessions.filter { $0.chat.needsAzureSignIn } }

    /// Each session that hit the expired sign-in is told it works now and carries on; a busy one gets it when its turn ends.
    func resumeAfterAzureSignIn(expires: String?) {
        let waiting = sessionsWaitingOnAzure
        for chat in azureSignIn.reportedChats.allObjects { chat.needsAzureSignIn = false }
        azureSignIn.reportedChats.removeAllObjects()
        azureSignIn.problem = nil
        let text = AzureSignIn.resumeMessage(expires: expires)
        for s in waiting {
            if s.chat.isBusy {
                s.chat.azureSignedIn(queued: true)
                s.inbox.append((text, text))
            } else {
                send(text, in: s)
                s.chat.azureSignedIn(queued: false)
            }
        }
        notice = waiting.isEmpty ? "Azure is signed in again."
            : "Azure is signed in again. \(waiting.count) session\(waiting.count == 1 ? "" : "s") carried on."
    }

    /// Opens Terminal on `az logout` and `az login`, then the token check, for when signing in from the app doesn't work.
    func azureLoginInTerminal() {
        guard let az = azureCLI else {
            errorMessage = azureMissing
            return
        }
        azureSignIn.cancel()
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let exe = quote(az.path)
        let script = """
        #!/bin/zsh -il
        clear
        echo "Sign in to Azure for Mindmill. When the last line prints a time, go back to Mindmill and press Check Again."
        echo
        tenant=$(\(exe) account show --query tenantId -o tsv 2>/dev/null)
        \(exe) logout 2>/dev/null
        if [ -n "$tenant" ]; then \(exe) login --tenant "$tenant"; else \(exe) login; fi
        echo
        echo "Token check:"
        \(exe) account get-access-token --resource \(AzureSignIn.devOpsResource) --query expiresOn -o tsv
        """
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("KB")
        let url = dir.appendingPathComponent("azure-login.command")
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
}

/// Under a session's conversation when it says the Azure sign-in expired.
struct AzureSignInCard: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession

    var body: some View {
        AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 220) {
            Image(systemName: "key.horizontal.fill").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Azure DevOps needs you to sign in again").font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Mindmill can run az login for you; the session carries on once the token check passes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button("Not Now") { session.chat.needsAzureSignIn = false }
                    .help("Hide this. Sign In to Azure… stays in the Mindmill menu.")
                Button("Sign In to Azure…") { model.openAzureSignIn() }
                    .buttonStyle(.borderedProminent)
            }
            .fixedSize()
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
    }
}

/// Signs the Azure CLI in through the browser, the way `az login` does in a terminal.
struct AzureSignInSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let signIn = model.azureSignIn
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal.fill").font(.title2).foregroundStyle(Color.accentColor)
                Text("Sign in to Azure").font(.title2.weight(.semibold))
            }
            Text("The Azure DevOps tools sign in through the Azure CLI. Its sign-in lapses after 90 days without use, and then comments, work items and pull requests can't be reached.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    Button("Use Terminal Instead") { model.azureLoginInTerminal() }
                        .help("Runs az logout, az login and the token check in Terminal. Come back and press Check Again when it's done.")
                    Button("Check Again") { model.checkAzureSignIn() }
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

    private func isDone(_ phase: AzureCLISignIn.Phase) -> Bool {
        if case .done = phase { return true }
        return false
    }

    private func until(_ expires: String?) -> String {
        expires.map { " (the token lasts until \($0))" } ?? ""
    }

    @ViewBuilder
    private func content(_ signIn: AzureCLISignIn) -> some View {
        switch signIn.phase {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the Azure sign-in…").foregroundStyle(.secondary)
            }
        case .working(let expires):
            Text("The token check passes\(until(expires)).").fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                let waiting = model.sessionsWaitingOnAzure.count
                if waiting > 0 {
                    Button(waiting == 1 ? "Continue the Session" : "Continue \(waiting) Sessions") {
                        model.resumeAfterAzureSignIn(expires: expires)
                        signIn.phase = .done(expires)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Sign In Again Anyway") { model.startAzureLogin() }
            }
        case .signedOut(let reason):
            Text("The Azure CLI can't get an Azure DevOps token. Your browser opens on the Microsoft sign-in page; sign in with your work account and come back.")
                .fixedSize(horizontal: false, vertical: true)
            if let reason {
                Text(reason).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Sign In in the Browser") { model.startAzureLogin() }
                .buttonStyle(.borderedProminent)
        case .waiting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finish signing in in your browser. Mindmill checks the token and carries on by itself when you're done.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = signIn.url {
                ChipRow(spacing: 10) {
                    Text("Browser didn't open?").foregroundStyle(.secondary)
                    Button("Open the Sign-In Page") { NSWorkspace.shared.open(url) }
                    CopyButton(label: "Copy Link", text: url.absoluteString)
                }
                .font(.callout)
            }
        case .done(let expires):
            Label("Signed in\(until(expires)). The sessions that were waiting carry on.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label("Signing in didn't finish.", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ChipRow(spacing: 10) {
                Button("Try Again") { model.startAzureLogin() }
                    .buttonStyle(.borderedProminent)
                Button("Sign Out First and Try Again") { model.startAzureLogin(signOutFirst: true) }
                    .help("Runs az logout first, which clears every cached Azure sign-in, then az login")
            }
        }
    }
}
