import AppKit
import KBCore
import KBEngine
import SwiftUI

/// Under the transcript header: pick a window or screen (or an area of it) for KB to read along with, or what it is
/// watching now.
struct ScreenRow: View {
    @Bindable var c: MeetingController
    @State private var picking = false
    @State private var choosingArea = false

    var body: some View {
        let s = c.screen
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let w = s.watching {
                    if let icon = w.icon {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "macwindow").font(.caption)
                    }
                    Text(w.name).font(.caption).lineLimit(1).truncationMode(.middle)
                        .layoutPriority(-1)
                        .help("Mindmill reads the text in “\(w.name)”\(s.area == nil ? "" : " (the area you chose)") when it changes and adds what is new to the transcript")
                    if s.area != nil {
                        Image(systemName: "crop").font(.caption).foregroundStyle(.tint).help("Only the area you chose")
                    }
                    if s.picturesOnChange {
                        Image(systemName: "photo.on.rectangle").font(.caption).foregroundStyle(.tint)
                            .help("\(Brain.name) is shown a picture when it changes a lot, like a new slide")
                    }
                    if s.reading {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 4)
                    Button {
                        c.showScreenToClaude()
                    } label: {
                        Label("Show \(Brain.name) This", systemImage: "camera.viewfinder").lineLimit(1).fixedSize()
                    }
                    .disabled(c.sendingPicture || c.stage != .live)
                    .help("Send \(Brain.name) one picture of \(s.area == nil ? "it" : "the area") now, for a diagram, chart or mockup. It is deleted after \(Brain.name) reads it.")
                    Menu {
                        Button("Choose an Area…") { choosingArea = true }
                        if s.area != nil { Button("Read All of It") { s.setArea(nil) } }
                        Toggle("Show \(Brain.name) Each New Slide", isOn: Binding(get: { s.picturesOnChange }, set: { s.picturesOnChange = $0 }))
                        Divider()
                        Button("Watch Something Else…") { picking = true }
                        Button("Stop Watching") { c.stopWatchingScreen() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Choose an area, pictures of new slides, or another window")
                } else {
                    Button { picking = true } label: {
                        Label("Read Along With a Window or Screen…", systemImage: "macwindow.on.rectangle").lineLimit(1)
                    }
                    .help("Pick the call, the shared slides or a whole screen, and optionally an area of it. Mindmill reads its text on this Mac and adds what is new to the transcript, so \(Brain.name) knows what is on screen.")
                    Spacer()
                }
            }
            if s.watching != nil {
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        FollowingDot(live: c.stage == .live)
                        Text(followText(s, now: context.date)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let error = s.error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                if s.permissionMissing {
                    HStack(spacing: 8) {
                        Button("Reset Permission") { LiveTranscriber.resetScreenPermission() }
                        Button("Reopen Mindmill") { LiveTranscriber.relaunch() }
                    }
                }
            }
        }
        .controlSize(.small)
        .sheet(isPresented: $picking) {
            WindowPicker(c: c) { picking = false }
        }
        .sheet(isPresented: $choosingArea) { ScreenAreaPicker(screen: s) }
    }
}

extension ScreenRow {
    /// What following does right now, in a line: that it reads, when it last found something new, and what Claude
    /// gets.
    func followText(_ s: ScreenWatcher, now: Date) -> String {
        var parts: [String] = []
        if c.stage != .live {
            parts.append("Following starts when the meeting is live")
        } else {
            parts.append(s.reading ? "Following live · reading now" : "Following live · checks every \(Int(ScreenWatcher.interval)) s")
        }
        if let at = s.lastChange {
            let ago = Int(now.timeIntervalSince(at))
            parts.append("new text \(ago < 60 ? "\(ago) s" : "\(ago / 60) min") ago" + (s.lastSnippet.map { ": “\($0)”" } ?? ""))
        } else if c.stage == .live {
            parts.append("no text yet")
        }
        if s.picturesOnChange {
            parts.append(s.lastPicture.map { "\(Brain.name) saw the last new slide \(RelativeTime.short($0)) ago" } ?? "\(Brain.name) sees each new slide")
        }
        return parts.joined(separator: " · ")
    }
}

/// A dot that pulses while KB follows the screen in a live meeting.
private struct FollowingDot: View {
    let live: Bool

    var body: some View {
        Pulsing(active: live, duration: 0.9) { on in
            Circle().fill(live ? Color.red : Color.secondary).frame(width: 7, height: 7).opacity(on ? 0.3 : 1)
        }
    }
}

/// A picture of the watched window or screen to drag an area on; only that area is read from then on.
struct ScreenAreaPicker: View {
    let screen: ScreenWatcher
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var failed: String?
    @State private var area: CGRect?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an Area").font(.title3.weight(.semibold))
            Text("Drag over the part Mindmill should read, like the slide in a call or one panel of a dashboard. \(Brain.name) then only gets the text of that part, and pictures show only that part.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Group {
                if let image {
                    let ratio = CGFloat(image.width) / CGFloat(max(image.height, 1))
                    GeometryReader { geo in
                        let size = geo.size
                        ZStack(alignment: .topLeading) {
                            Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                            if let area {
                                let r = ScreenArea.rect(area, in: size)
                                Path { p in
                                    p.addRect(CGRect(origin: .zero, size: size))
                                    p.addRect(r)
                                }
                                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                                Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                                    .frame(width: r.width, height: r.height)
                                    .offset(x: r.minX, y: r.minY)
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                if let a = ScreenArea.area(from: v.startLocation, to: v.location, in: size) { area = a }
                            })
                    }
                    .aspectRatio(ratio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                } else if let failed {
                    Text(failed).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ProgressView("Taking a picture…").frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .frame(maxHeight: 520)
            HStack {
                Button("Read All of It") {
                    screen.setArea(nil)
                    dismiss()
                }
                .help("Read the whole window or screen again")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use This Area") {
                    screen.setArea(area)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(area == nil)
            }
        }
        .padding(20)
        .frame(width: 760)
        .task {
            area = screen.area
            do { image = try await screen.wholePicture() } catch { failed = "Couldn't take a picture: \(error.localizedDescription)" }
        }
    }
}

struct WindowPicker: View {
    let c: MeetingController
    var done: () -> Void
    @State private var loaded = false
    @State private var query = ""

    var body: some View {
        let s = c.screen
        VStack(alignment: .leading, spacing: 8) {
            Text("Follow a Window or Screen").font(.title3.weight(.semibold))
            Text("Only what you pick. Mindmill reads its text on this Mac when it changes; the text goes into the transcript and to \(Brain.name). Choose an area of it afterwards from ⋯. Pictures go to \(Brain.name) only when you press Show \(Brain.name) This, or turn on Show \(Brain.name) Each New Slide.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Search windows", text: $query).textFieldStyle(.roundedBorder)
            Divider()
            if !loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if s.windows.isEmpty && s.displays.isEmpty {
                Text(s.error ?? "No windows to watch.").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if !s.displays.isEmpty && query.isEmpty {
                            Text("Screens").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 6)
                            ForEach(s.displays) { d in
                                Button {
                                    c.watchScreen(d)
                                    done()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "display").frame(width: 18, height: 18)
                                        Text(d.title).font(.callout)
                                        Spacer(minLength: 0)
                                        if s.watching?.id == d.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            Text("Windows").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.top, 6)
                        }
                        ForEach(s.windows.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { w in
                            Button {
                                c.watchScreen(w)
                                done()
                            } label: {
                                HStack(spacing: 8) {
                                    if let icon = w.icon {
                                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                                    }
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(w.app).font(.callout)
                                        if !w.title.isEmpty {
                                            Text(w.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if s.watching?.id == w.id {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            Divider()
            HStack {
                Toggle("Show \(Brain.name) each new slide", isOn: Binding(get: { s.picturesOnChange }, set: { s.picturesOnChange = $0 }))
                    .toggleStyle(.checkbox)
                    .help("When it changes a lot, like a new slide, \(Brain.name) gets a picture of it (at most every \(Int(ScreenWatcher.autoPictureGap)) s), so it sees diagrams and charts too")
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 520, height: 640)
        .task {
            await s.refreshWindows()
            loaded = true
        }
    }
}
