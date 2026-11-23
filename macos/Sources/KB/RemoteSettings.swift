import AppKit
import CoreImage.CIFilterBuiltins
import KBCore
import SwiftUI

/// Settings → Remote: let the Mindmill app on a phone reach this Mac, on the same network or over Tailscale.
/// Server status first, then pairing, the paired phones, and what to check when it doesn't connect.
struct RemoteSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(RemoteServer.enabledKey) private var enabled = false
    @AppStorage(RemoteServer.portKey) private var port = RemoteServer.defaultPort

    var body: some View {
        let remote = model.remote
        Form {
            Section {
                Toggle("Let paired phones use this Mac", isOn: Binding(get: { enabled }, set: { model.setRemoteEnabled($0) }))
                RemoteStatusView(remote: remote, enabled: enabled)
                LabeledContent("Port") {
                    TextField("Port", value: $port, format: .number.grouping(.never))
                        .labelsHidden()
                        .frame(maxWidth: 90)
                        .disabled(enabled && remote.isRunning)
                        .onSubmit { if enabled { remote.restart() } }
                }
                .help(enabled && remote.isRunning ? "Turn remote access off to change the port" : "Press Return to use the new port")
            } header: {
                Text("Remote access")
            }
            if enabled, remote.isRunning {
                Section("Pair a phone") { PairingView(remote: remote) }
            }
            Section("Paired phones") { PairedPhonesView(remote: remote) }
            Section { TroubleshootingView() }
        }
        .formStyle(.grouped)
        .multilineTextAlignment(.leading)
        .frame(minWidth: 340, maxWidth: 560)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Off, starting, running with the addresses a phone can use, waiting for the network, or failed with the reason
/// and when it tries again.
private struct RemoteStatusView: View {
    let remote: RemoteServer
    let enabled: Bool

    var body: some View {
        if !enabled {
            Label("Off. Phones can't reach this Mac.", systemImage: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(.secondary)
        } else {
            switch remote.status {
            case .off, .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting…").foregroundStyle(.secondary)
                }
            case .running(let port):
                AdaptiveCardLayout {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Running on port \(String(port))", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                        AddressList(addresses: remote.addresses)
                    }
                    Button("Restart") { remote.restart() }
                        .help("Stop listening and start again; connected phones reconnect by themselves")
                }
            case .waiting(let reason):
                problem(title: "Waiting for the network", reason: reason, retryAt: nil)
            case .failed(let reason, let retryAt):
                problem(title: "Not running", reason: reason, retryAt: retryAt)
            }
        }
    }

    private func problem(title: String, reason: String, retryAt: Date?) -> some View {
        AdaptiveCardLayout {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let retryAt {
                    SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let left = Int(max(0, retryAt.timeIntervalSince(ctx.date)).rounded(.up))
                        Text(left > 0 ? "Trying again in \(left) s." : "Trying again…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button("Retry Now") { remote.restart() }
        }
    }
}

private struct AddressList: View {
    let addresses: [String]

    var body: some View {
        if addresses.isEmpty {
            Text("No network address yet. Connect this Mac to Wi-Fi, Ethernet or Tailscale.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(addresses, id: \.self) { a in
                    ChipRow(spacing: 6) {
                        Text(a).font(.caption.monospaced()).textSelection(.enabled)
                        Text(RemoteAddresses.label(a)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// The QR code and code while a phone may pair, then how it went.
private struct PairingView: View {
    let remote: RemoteServer

    var body: some View {
        if let outcome = remote.pairingOutcome, remote.pairing == nil {
            switch outcome {
            case .paired(let name):
                AdaptiveCardLayout {
                    Label("\(name) paired", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    ChipRow {
                        Button("Pair Another Phone") { remote.pairing = .new() }
                        Button("Done") { remote.pairingOutcome = nil }
                    }
                }
            case .failed(let reason):
                AdaptiveCardLayout {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Pairing didn't work", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Try Again") { remote.pairing = .new() }
                }
            }
        } else if let code = remote.pairing, let invite = remote.invite() {
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = Int(code.expires.timeIntervalSince(ctx.date))
                if left <= 0 {
                    AdaptiveCardLayout {
                        Label("The code expired before a phone used it.", systemImage: "clock.badge.xmark")
                            .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        Button("Show a New Code") { remote.pairing = .new() }
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            QRCodeImage(text: invite.url).frame(width: 170, height: 170)
                            details(code: code, left: left)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            QRCodeImage(text: invite.url).frame(width: 170, height: 170)
                            details(code: code, left: left)
                        }
                    }
                }
            }
        } else {
            AdaptiveCardLayout {
                Text("Open Mindmill on the phone, choose Pair with a Mac, and scan the code shown here.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Show Pairing Code") { remote.pairing = .new() }
            }
        }
    }

    private func details(code: PairingCode, left: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scan this with the Mindmill app on your phone, or type the code:")
                .fixedSize(horizontal: false, vertical: true)
            Text(code.code).font(.title.monospacedDigit().weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for the phone…").foregroundStyle(.secondary)
            }
            if remote.wrongAttempts > 0 {
                Text("A phone tried a wrong code (\(remote.wrongAttempts) of \(RemoteServer.maxPairingAttempts)).")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("For one phone. Expires in \(left / 60):\(String(format: "%02d", left % 60)).")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button("Cancel") { remote.pairing = nil }
        }
    }
}

private struct PairedPhonesView: View {
    let remote: RemoteServer
    @State private var renaming: RemoteDevices.Device?
    @State private var newName = ""
    @State private var removing: RemoteDevices.Device?

    var body: some View {
        Group {
            if remote.devices.devices.isEmpty {
                Text("None yet. Pair a phone above.").foregroundStyle(.secondary)
            }
            ForEach(remote.devices.devices) { d in
                let online = remote.connected[d.id] != nil
                AdaptiveCardLayout {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.name)
                        Text(online ? "Connected now"
                             : d.lastSeen.map { "Last seen \($0.formatted(.relative(presentation: .named)))" }
                             ?? "Paired \(d.paired.formatted(date: .abbreviated, time: .omitted)), not connected since")
                            .font(.caption).foregroundStyle(online ? .green : .secondary)
                    }
                    ChipRow {
                        Button("Rename…") { newName = d.name; renaming = d }
                        Button("Remove…", role: .destructive) { removing = d }
                            .help("This phone can't connect any more until it pairs again")
                    }
                }
            }
        }
        .alert("Rename Phone", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let d = renaming { remote.rename(d.id, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let d = removing { remote.revoke(d.id) }; removing = nil }
        } message: {
            Text("It is disconnected now and has to pair again to use this Mac.")
        }
    }
}

private struct TroubleshootingView: View {
    var body: some View {
        DisclosureGroup("If the phone can't connect") {
            VStack(alignment: .leading, spacing: 6) {
                tip("Same network or Tailscale", "The phone and this Mac must be on the same Wi-Fi, or both signed in to your Tailscale tailnet.")
                tip("Mindmill must be running", "The Mac answers only while Mindmill is open and the Mac is awake.")
                tip("Firewall", "If macOS asked whether Mindmill may accept incoming connections, allow it. Check System Settings → Network → Firewall → Options.")
                tip("Guest or office networks", "Some networks stop devices from reaching each other. Use Tailscale there.")
                tip("Still nothing", "Press Restart above, then pair the phone again.")
            }
            .padding(.top, 4)
        }
    }

    private func tip(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.callout.weight(.medium))
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A QR code for some text, drawn sharp at any size.
struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.make(text) {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
        } else {
            Color.secondary.opacity(0.1)
        }
    }

    static func make(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
