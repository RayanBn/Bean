import AppKit
import Quartz
import SwiftUI

// A folder an agent is at, from what really happened: the session it runs, the document open in its app, its own home.
struct AgentPlace: Identifiable, Equatable {
    let path: String
    let words: String

    var id: String { path }
    var shortPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

enum AgentPlaces {
    static func read(_ context: WidgetContext) async -> [AgentPlace] {
        let session = context.session?.folder
        let apps = context.agent.attachments
        let own = context.actions.agentFolder(context.agent.id)?.path
        return await Task.detached {
            var places: [AgentPlace] = []
            if let session, FileManager.default.fileExists(atPath: session) { places.append(AgentPlace(path: session, words: "Its session's folder")) }
            for app in apps {
                if let folder = documentFolder(of: app), !places.contains(where: { $0.path == folder }) { places.append(AgentPlace(path: folder, words: "Its document's folder")) }
            }
            if let own { places.append(AgentPlace(path: own, words: "Its own folder")) }
            return places
        }.value
    }

    private static func documentFolder(of attachment: Attachment) -> String? {
        guard let pid = attachment.runningPid, OffLimits.match("\(attachment.appName) \(attachment.bundleId) \(attachment.windowTitle ?? "")") == nil else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard let value = Accessibility.attribute(name, of: app), CFGetTypeID(value) == AXUIElementGetTypeID(),
                  let document = Accessibility.attribute(kAXDocumentAttribute, of: value as! AXUIElement) as? String,
                  let url = URL(string: document), url.isFileURL else { continue }
            let folder = url.deletingLastPathComponent().path
            if FileManager.default.fileExists(atPath: folder) { return folder }
        }
        return nil
    }
}

struct FileRow: Identifiable, Equatable {
    let url: URL
    let isFolder: Bool
    let modified: Date?

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    static func list(in folder: URL) -> [FileRow] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return found.prefix(2000).filter { OffLimits.match($0.lastPathComponent) == nil }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FileRow(url: url, isFolder: values?.isDirectory == true, modified: values?.contentModificationDate)
        }.sorted { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
    }
}

// The list beside the reading when the widget is wide, and one at a time when it is narrow.
private struct ListAndReading<List: View, Reading: View>: View {
    let reading: Bool
    let back: () -> Void
    @ViewBuilder let list: () -> List
    @ViewBuilder let read: () -> Reading

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 460 {
                HStack(spacing: 0) {
                    list().frame(width: min(240, proxy.size.width * 0.4))
                    Divider()
                    read().frame(maxWidth: .infinity)
                }
            } else if reading {
                VStack(alignment: .leading, spacing: 0) {
                    Button(action: back) { Label("Back", systemImage: "chevron.left").font(.widgetSmall) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 8).frame(height: 22)
                        .accessibilityIdentifier("page-file-back")
                    Divider()
                    read()
                }
            } else {
                list()
            }
        }
    }
}

struct FilesWidget: View {
    let context: WidgetContext
    @State private var places: [AgentPlace] = []
    @State private var root: String?
    @State private var open: Set<String> = []
    @State private var listed: [String: [FileRow]] = [:]
    @State private var reading: URL?

    private var place: AgentPlace? { places.first { $0.path == root } ?? places.first }

    private var rows: [(row: FileRow, depth: Int)] {
        guard let place else { return [] }
        func walk(_ path: String, _ depth: Int) -> [(row: FileRow, depth: Int)] {
            (listed[path] ?? []).flatMap { row in
                [(row, depth)] + (row.isFolder && open.contains(row.id) ? walk(row.id, depth + 1) : [])
            }
        }
        return walk(place.path, 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            placeBar
            Divider()
            ListAndReading(reading: reading != nil, back: { reading = nil }) {
                list
            } read: {
                if let reading {
                    FileReading(url: reading).id(reading)
                } else {
                    WidgetEmpty(icon: "doc.text", title: "Pick a file", text: "It opens here. Nothing is changed.")
                }
            }
        }
        .task(id: context.session?.folder) {
            places = await AgentPlaces.read(context)
        }
        .task(id: "\(place?.path ?? "") \(open.count)") {
            guard let place else { return }
            let paths = [place.path] + open
            while !Task.isCancelled {
                await PageVisibility.wait()
                let fresh = await Task.detached { Dictionary(paths.map { ($0, FileRow.list(in: URL(fileURLWithPath: $0))) }, uniquingKeysWith: { first, _ in first }) }.value
                if fresh != listed { listed = fresh }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var placeBar: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(places) { place in
                    Button { root = place.path; reading = nil } label: { Text(place.words + ": " + place.shortPath) }
                }
            } label: {
                Text(place?.words ?? "").font(Font.widgetSmall.weight(.medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Which of its folders to show")
            .accessibilityIdentifier("page-files-place")
            if let place {
                Text(place.shortPath).font(.widgetMono).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading).help(place.path)
                Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: place.path) } label: { Image(systemName: "arrow.up.forward.app").font(.widgetSmall) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder").accessibilityLabel("Show in Finder")
            }
        }
        .padding(.horizontal, 8).frame(height: 26)
    }

    @ViewBuilder private var list: some View {
        let rows = rows
        if let place, listed[place.path]?.isEmpty == true {
            WidgetEmpty(icon: "folder", title: "This folder is empty", text: "What \(context.name) saves here shows up by itself.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.row.id) { row, depth in
                        Button {
                            if row.isFolder {
                                if open.contains(row.id) { open.remove(row.id) } else { open.insert(row.id) }
                            } else {
                                reading = row.url
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                                    .rotationEffect(.degrees(open.contains(row.id) ? 90 : 0)).opacity(row.isFolder ? 1 : 0).frame(width: 9)
                                Image(nsImage: NSWorkspace.shared.icon(forFile: row.id)).resizable().frame(width: 14, height: 14)
                                Text(row.name).font(.widgetBody).lineLimit(1).truncationMode(.middle).help(row.id)
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, CGFloat(depth) * 12 + 6).padding(.trailing, 6).frame(height: 22)
                            .background(reading == row.url ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("page-file-\(row.name)")
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }
}

// Memory is small text files with one writer each, so this view reads them and changes nothing.
struct MemoryWidget: View {
    struct Item: Identifiable, Equatable {
        let title: String
        let blurb: String
        let url: URL
        let empty: String
        var hasText = false
        var modified: Date?

        var id: String { url.path }
    }

    let context: WidgetContext
    @State private var items: [Item] = []
    @State private var chosen: String?

    private var chosenItem: Item? { items.first { $0.id == chosen } }

    var body: some View {
        ListAndReading(reading: chosenItem != nil, back: { chosen = nil }) {
            list
        } read: {
            if let item = chosenItem {
                if item.hasText {
                    FileReading(url: item.url).id(item.id)
                } else {
                    WidgetEmpty(icon: "brain", title: "Nothing here yet", text: item.empty)
                }
            } else {
                WidgetEmpty(icon: "brain", title: "Pick what to read", text: "\(context.name) reads these at the start of each run. They are plain files.")
            }
        }
        .task(id: context.agent.id) {
            guard let url = context.actions.agentFolder(context.agent.id) else { return }
            let name = context.name
            while !Task.isCancelled {
                await PageVisibility.wait()
                let fresh = await Task.detached { Self.read(AgentFolder(url: url), name: name) }.value
                if fresh != items { items = fresh }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private static func read(_ folder: AgentFolder, name: String) -> [Item] {
        var items = [
            Item(title: "Its notes", blurb: "What \(name) learned and chose to keep.", url: folder.notes, empty: "\(name) writes here when it learns something worth keeping."),
            Item(title: "Your corrections", blurb: "What you told it to do differently.", url: folder.correctionsFile.url, empty: "When you correct \(name), the correction is kept here."),
            Item(title: "What it sees", blurb: "Its understanding of the app it is on.", url: folder.window, empty: "\(name) writes this once it is on an app."),
            Item(title: "About you", blurb: "What you said about yourself. Every agent reads it.", url: MemoryFile.user.url, empty: "When you tell an agent something about yourself, it is kept here."),
            Item(title: "Your goals", blurb: "What you want, in your words. Every agent reads it.", url: Goals.file.url, empty: "Tell Bean a goal in the chat, and it is kept here."),
            Item(title: "Its job card", blurb: "Who it is, its job, and its limits.", url: folder.cardFile, empty: "This agent has no card yet."),
        ]
        let known = Set(items.map(\.url.lastPathComponent))
        for row in FileRow.list(in: folder.memory) where !row.isFolder && !known.contains(row.name) {
            items.append(Item(title: row.name, blurb: "Kept in its memory folder.", url: row.url, empty: "This file is empty."))
        }
        return items.map { item in
            var item = item
            let values = try? item.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            item.hasText = (values?.fileSize ?? 0) > 0
            item.modified = values?.contentModificationDate
            return item
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    Button { chosen = item.id } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(item.title).font(Font.widgetBody.weight(.medium)).foregroundStyle(item.hasText ? Color.primary : Color.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                if !item.hasText {
                                    Text("Empty").font(.widgetSmall).foregroundStyle(.tertiary)
                                } else if let modified = item.modified {
                                    Text(modified.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))).font(.widgetSmall).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }
                            Text(item.blurb).font(.widgetSmall).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(chosen == item.id ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("page-memory-\(item.url.lastPathComponent)")
                }
            }
            .padding(.vertical, 3)
        }
    }
}

// Reads any file in place: text and notes as text the system can select, anything else through Quick Look. It follows the file as it changes.
struct FileReading: View {
    private enum Content: Equatable {
        case text(String, markdown: Bool, cut: Bool)
        case quickLook
        case hidden
    }

    private static let textLimit = 400_000

    let url: URL
    @State private var content: Content?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(url.lastPathComponent).font(Font.widgetSmall.weight(.medium)).lineLimit(1).truncationMode(.middle).help(url.path)
                Spacer(minLength: 4)
                if case .text(_, _, true) = content { Text("Only the start is shown").font(.widgetSmall).foregroundStyle(.tertiary).fixedSize() }
                Button("Open") { NSWorkspace.shared.open(url) }.controlSize(.mini).help("Open in its usual app").accessibilityIdentifier("page-file-open")
            }
            .padding(.horizontal, 8).frame(height: 24)
            Divider()
            switch content {
            case .text(let text, let markdown, _):
                ReadOnlyText(text: text, markdown: markdown)
            case .quickLook:
                QuickLookView(url: url)
            case .hidden:
                WidgetEmpty(icon: "eye.slash", title: "Off limits", text: "This file holds words on your off limits list.")
            case nil:
                Color.clear
            }
        }
        .task(id: url) {
            let url = url
            var seen: Date?
            while !Task.isCancelled {
                await PageVisibility.wait()
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if modified != seen || content == nil {
                    seen = modified
                    content = await Task.detached { Self.load(url) }.value
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private static func load(_ url: URL) -> Content {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .quickLook }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: textLimit + 1)) ?? Data()
        let looksBinary = data.prefix(4096).contains(0)
        guard !looksBinary, let text = String(data: data, encoding: .utf8) ?? (data.count > textLimit ? String(decoding: data.dropLast(4), as: UTF8.self) : nil) else { return .quickLook }
        let redacted = OffLimits.redact(text)
        if redacted.hidden > 0, redacted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .hidden }
        return .text(redacted.text, markdown: ["md", "markdown"].contains(url.pathExtension.lowercased()), cut: data.count > textLimit)
    }
}

private struct ReadOnlyText: NSViewRepresentable {
    let text: String
    let markdown: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.setAccessibilityIdentifier("page-file-text")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.textStorage?.setAttributedString(markdown ? Self.notes(text) : NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor]))
    }

    private static func notes(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var inFrontMatter = false
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let body = NSFont.systemFont(ofSize: 12)
            var font = body, color = NSColor.labelColor
            var shown = line
            if line == "---", index == 0 || inFrontMatter {
                inFrontMatter = index == 0
                color = .tertiaryLabelColor
            } else if inFrontMatter {
                font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                color = .secondaryLabelColor
            } else if let level = Optional(line.prefix { $0 == "#" }.count), (1...4).contains(level), line.dropFirst(level).hasPrefix(" ") {
                shown = String(line.dropFirst(level + 1))
                font = .systemFont(ofSize: level == 1 ? 15 : 13, weight: .semibold)
            } else if line.hasPrefix("- ") {
                shown = "•  " + line.dropFirst(2)
            }
            result.append(NSAttributedString(string: shown + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        return result
    }
}

private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = true
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
