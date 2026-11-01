import AppKit
import ScreenCaptureKit
import SwiftUI

// One picture at a time, from a list that is slow to read and so is kept for a moment. Only ever used once the person has allowed Screen Recording.
actor WindowPictures {
    static let shared = WindowPictures()

    private var listed: (at: Date, windows: [SCWindow])?

    func picture(of number: Int, width: CGFloat? = nil) async -> NSImage? {
        guard SpaceWindows.picturesWork, let window = await window(number) else { return nil }
        let scale = width.map { min(1, $0 / max(window.frame.width, 1)) } ?? 1
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale * 2))
        configuration.height = max(1, Int(window.frame.height * scale * 2))
        configuration.showsCursor = false
        guard let shot = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration) else { return nil }
        return NSImage(cgImage: shot, size: NSSize(width: window.frame.width * scale, height: window.frame.height * scale))
    }

    private func window(_ number: Int) async -> SCWindow? {
        if let listed, Date().timeIntervalSince(listed.at) < 5, let found = listed.windows.first(where: { Int($0.windowID) == number }) { return found }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return nil }
        listed = (Date(), content.windows)
        return content.windows.first { Int($0.windowID) == number }
    }
}

struct AppIcon: View {
    let bundleId: String
    let size: CGFloat

    private var image: NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
    }

    var body: some View {
        Image(nsImage: image).resizable().frame(width: size, height: size)
    }
}

// A live picture of one window with a caption saying whose it is, or, with no permission, what can be read from it and how to get the picture.
struct WindowWidget<Controls: View>: View {
    let attachment: Attachment
    @ViewBuilder let controls: () -> Controls
    @State private var image: NSImage?
    @State private var text: String?
    @State private var shut = false
    @State private var read = false

    private var isOpen: Bool { BoardWindows.isOpen(bundleId: attachment.bundleId, words: "\(attachment.appName) \(attachment.bundleId) \(attachment.windowTitle ?? "")") }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                AppIcon(bundleId: attachment.bundleId, size: 14)
                Text(attachment.appName).font(Font.widgetSmall.weight(.medium)).fixedSize()
                if let title = attachment.windowTitle, !title.isEmpty {
                    Text(title).font(.widgetSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(title)
                }
                Spacer(minLength: 4)
                if image != nil {
                    HStack(spacing: 3) {
                        Circle().fill(.green).frame(width: 5, height: 5)
                        Text("Live").font(.widgetSmall).foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .help("This is a picture. Clicks here do not reach the app.")
                }
                controls()
                Button("Open") { Self.bringForward(attachment) }.controlSize(.mini).help("Bring this window to the front").accessibilityIdentifier("page-window-open")
            }
            .padding(.horizontal, 8).frame(height: 26)
            Divider()
            content
        }
        .task(id: attachment.windowNumber) {
            image = nil
            read = false
            while !Task.isCancelled {
                guard isOpen else {
                    image = nil
                    text = nil
                    shut = true
                    return
                }
                if SpaceWindows.picturesWork, let shot = await WindowPictures.shared.picture(of: attachment.windowNumber) {
                    image = shot
                    try? await Task.sleep(for: .seconds(NSApp.isActive ? 1 : 4))
                } else {
                    let attachment = attachment
                    let snapshot = await Task.detached { WindowSnapshot.read(attachment) }.value
                    image = nil
                    text = snapshot?.text
                    read = true
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("page-window-picture")
        } else if shut {
            WidgetEmpty(icon: "eye.slash", title: "Closed to Bean", text: "This app is sealed or on your off limits list, so nothing is shown here.")
        } else if read {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                    Text("Turn on Screen Recording to see a live picture here.").font(.widgetSmall).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).help("In System Settings, allow Bean under Screen Recording, then reopen Bean.")
                    Spacer(minLength: 4)
                    Button("Open Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
                        .controlSize(.mini).fixedSize().accessibilityIdentifier("page-window-permission")
                }
                .padding(8)
                .background(.quaternary.opacity(0.5))
                Divider()
                if let text, !text.isEmpty {
                    ScrollView { Text(text).font(.widgetBody).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    WidgetEmpty(icon: "text.magnifyingglass", title: "Nothing to read", text: "This window shows no text that Bean can read.")
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func bringForward(_ attachment: Attachment) {
        guard let pid = attachment.runningPid else { return }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}

enum BoardWindows {
    static func attachment(for number: Int, windows: [OpenWindow]) -> Attachment? {
        guard let window = windows.first(where: { $0.number == number }), isOpen(window) else { return nil }
        return Attachment(bundleId: window.bundleId, appName: window.app, pid: window.pid, windowNumber: window.number, windowTitle: window.title)
    }

    static func isOpen(_ window: OpenWindow) -> Bool {
        isOpen(bundleId: window.bundleId, words: "\(window.app) \(window.bundleId) \(window.title ?? "")")
    }

    static func isOpen(bundleId: String, words: String) -> Bool {
        Skills.forApp(bundleId)?.sealed != true && OffLimits.match(words) == nil
    }
}

// The whole app is an agent's work, so its widget can follow any of the app's windows.
struct AppWidget: View {
    let context: WidgetContext
    @State private var chosen: Int?

    private var agent: Agent { context.agent }

    var body: some View {
        if let attachment = agent.attachment {
            let windows = context.feed.openWindows.filter { $0.bundleId == attachment.bundleId && BoardWindows.isOpen($0) }
            let shown = chosen.flatMap { BoardWindows.attachment(for: $0, windows: windows) } ?? attachment
            WindowWidget(attachment: shown) {
                if windows.count > 1 {
                    Menu {
                        ForEach(windows, id: \.number) { window in
                            Button(window.title ?? "Untitled") { chosen = window.number }
                        }
                    } label: {
                        Text("\(windows.count) windows").font(.widgetSmall)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Which of this app's windows to show")
                    .accessibilityIdentifier("page-app-windows")
                }
            }
        } else {
            WidgetEmpty(icon: "macwindow", title: "\(context.name) is not on an app", text: "Drag its drop, above, onto any app. That app becomes its work, and you watch it here.") {
                Menu("Put on an App") {
                    ForEach(context.appChoices, id: \.number) { window in
                        Button(window.app) { context.actions.putOnApp(agent.id, window) }
                    }
                    if context.appChoices.isEmpty { Text("No apps are open.") }
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("page-app-put")
            }
        }
    }
}

// Any window on the Mac, to keep an eye on it or to hand its app to the agent.
struct WindowPane: View {
    let context: WidgetContext

    private var attachment: Attachment? {
        context.spec.param.flatMap(Int.init).flatMap { BoardWindows.attachment(for: $0, windows: context.feed.openWindows) }
    }

    var body: some View {
        if let attachment {
            WindowWidget(attachment: attachment) {
                if context.agent.attachment != attachment, let window = context.feed.openWindows.first(where: { $0.number == attachment.windowNumber }) {
                    Button(String(format: "Put %@ Here", context.name)) { context.actions.putOnApp(context.agent.id, window) }
                        .controlSize(.mini)
                        .fixedSize()
                        .help(String(format: "%@ works on %@ from now on", context.name, attachment.appName))
                        .accessibilityIdentifier("page-window-put")
                }
            }
        } else {
            WidgetEmpty(icon: "macwindow", title: "This window is gone", text: "It closed, or it is off limits. Close this widget, or add another window with Add Widget.")
        }
    }
}
