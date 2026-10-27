import AppKit
import ApplicationServices
import ScreenCaptureKit

final class StreamGuard {
    struct Finding {
        let key: String
        let kind: String
        let rect: CGRect
        let window: VisibleWindow
        let candidate: (Int) -> ShieldCandidate
    }

    struct Event: Encodable {
        let at = Date()
        let event: String
        var windows: Int?
        var shields: Int?
        var kinds: [String: Int]?
        var released: Int?
        var milliseconds: Int?
        var detail: String?
    }

    private let notch: NotchController
    private let policy: ShieldPolicy
    private let log: JSONLog
    private let watcher = ShareWatcher()
    private let shields = Shields()
    private let scanQueue = DispatchQueue(label: "bean.streamguard", qos: .userInitiated)
    private var model: PrivacyModel?
    private var findings: [String: Finding] = [:]
    private var released: Set<String> = []
    private var covers: [String: (rect: CGRect, at: Date)] = [:]
    private var asked: Set<String> = []
    private var scanning = false
    private var pending = false
    private var scanWork: DispatchWorkItem?
    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var windowOrigins: [CGWindowID: CGPoint] = [:]
    private var sharedAt: Date?
    private var scrollTap: CFMachPort?

    init(notch: NotchController, client: ModelClient, log: JSONLog) {
        self.notch = notch
        policy = ShieldPolicy(client: client)
        self.log = log
    }

    func start() {
        guard watcher.available else {
            log.append(Event(event: "unavailable", detail: "SkyLight screen watcher symbol missing"))
            return
        }
        watcher.onChange = { [weak self] sharing in self?.sharingChanged(sharing) }
        watcher.start()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.observe(app.processIdentifier)
            self?.scheduleScan()
        }
        if let front = NSWorkspace.shared.frontmostApplication { observe(front.processIdentifier) }
        if PrivacyModelStore.isInstalled { loadModel() } else { offerDownload() }
        watchScrolling()
    }

    private func watchScrolling() {
        let callback: CGEventTapCallBack = { _, _, event, refcon in
            if let refcon { Unmanaged<StreamGuard>.fromOpaque(refcon).takeUnretainedValue().scrolled(at: event.location) }
            return Unmanaged.passUnretained(event)
        }
        scrollTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                      eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue), callback: callback,
                                      userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let scrollTap, let source = CFMachPortCreateRunLoopSource(nil, scrollTap, 0) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func scrolled(at point: CGPoint) {
        guard watcher.isSharing else { return }
        let shielded = Set(findings.values.map(\.window.id))
        guard let window = ScreenText.visibleWindows().first(where: { $0.frame.contains(point) }), shielded.contains(window.id) else { return }
        let key = "cover|\(window.id)"
        if covers[key] == nil {
            covers[key] = (window.frame, Date())
            Task { await shields.prepare(shownRects()) }
        } else {
            covers[key]?.at = Date()
        }
        scheduleScan()
    }

    private func loadModel() {
        scanQueue.async { [weak self] in
            let started = Date()
            do {
                let model = try PrivacyModel(directory: PrivacyModelStore.directory)
                DispatchQueue.main.async {
                    self?.model = model
                    self?.log.append(Event(event: "model-loaded", milliseconds: Int(Date().timeIntervalSince(started) * 1000), detail: PrivacyModel.name))
                    self?.scheduleScan(after: 0)
                }
            } catch {
                DispatchQueue.main.async { self?.log.append(Event(event: "model-failed", detail: error.localizedDescription)) }
            }
        }
    }

    private func offerDownload() {
        guard !UserDefaults.standard.bool(forKey: "streamGuardDownloadDeclined") else { return }
        notch.show(NotchMessage(text: "To hide private things when you share your screen, I need an on-device privacy model: \(PrivacyModel.name), \(PrivacyModelStore.sizeLabel), not a Meta model. Nothing you share leaves this Mac.", choices: [
            NotchChoice(label: "Not now", isPrimary: false) { [weak self] in
                UserDefaults.standard.set(true, forKey: "streamGuardDownloadDeclined")
                self?.notch.rest()
            },
            NotchChoice(label: "Download", isPrimary: true) { [weak self] in
                self?.notch.rest()
                self?.log.append(Event(event: "download-started", detail: PrivacyModel.name))
                Task {
                    do {
                        try await PrivacyModelStore.download()
                        await MainActor.run {
                            self?.log.append(Event(event: "download-done"))
                            self?.loadModel()
                        }
                    } catch {
                        await MainActor.run { self?.log.append(Event(event: "download-failed", detail: error.localizedDescription)) }
                    }
                }
            },
        ]))
    }

    private func sharingChanged(_ sharing: Bool) {
        if sharing {
            sharedAt = Date()
            shields.raise()
            log.append(Event(event: "share-started", shields: shields.count, detail: model == nil ? "privacy model not loaded" : nil))
            scheduleScan(after: 0)
        } else {
            shields.lower()
            log.append(Event(event: "share-ended", shields: shields.count))
            sharedAt = nil
            if notch.model.phase.key == "message" { notch.rest() }
        }
    }

    private func scheduleScan(after delay: TimeInterval? = nil) {
        scanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? (watcher.isSharing ? 0.25 : 3)), execute: work)
    }

    private func scan() {
        guard let model else { return }
        guard !scanning else { pending = true; return }
        scanning = true
        let started = Date()
        let sharing = watcher.isSharing
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = await Self.find(model: model, everyWindow: sharing)
            await MainActor.run {
                guard let self else { return }
                self.apply(found, started: started, sharing: sharing)
            }
        }
    }

    private static func find(model: PrivacyModel, everyWindow: Bool) async -> [Finding] {
        let all = ScreenText.visibleWindows()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windows = everyWindow ? all : all.filter { $0.pid == front }
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var result: [Finding] = []
        for window in windows {
            for (index, rect) in ScreenText.secureFields(in: window).enumerated() {
                result.append(Finding(key: "\(window.id)|password|\(index)", kind: "password_field", rect: rect, window: window) {
                    ShieldCandidate(id: $0, app: window.app, window: window.title, type: "password_field", shape: "masked", before: "", after: "")
                })
            }
            var pieces = ScreenText.accessibilityPieces(in: window)
            if pieces.reduce(0, { $0 + $1.text.count }) < ScreenText.ocrBelowCharacters, let content {
                pieces = await ScreenText.ocrPieces(in: window, content: content)
            }
            for piece in pieces {
                guard let spans = try? model.spans(in: piece.text) else { continue }
                let ns = piece.text as NSString
                for span in spans {
                    let trimmed = Self.trim(span.range, in: ns)
                    guard trimmed.length > 0, let rect = piece.rect(trimmed) else { continue }
                    let value = ns.substring(with: trimmed)
                    let before = ns.substring(to: trimmed.location).split(whereSeparator: \.isWhitespace).suffix(3).joined(separator: " ")
                    let after = ns.substring(from: trimmed.location + trimmed.length).split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
                    let shape = ShieldPolicy.shape(of: value)
                    result.append(Finding(key: "\(window.id)|\(span.kind)|\(value.hashValue)", kind: span.kind, rect: rect.insetBy(dx: -3, dy: -2), window: window) {
                        ShieldCandidate(id: $0, app: window.app, window: window.title, type: span.kind, shape: shape, before: before, after: after)
                    })
                }
            }
        }
        return result.filter { finding in
            let center = CGPoint(x: finding.rect.midX, y: finding.rect.midY)
            return !all.prefix { $0.id != finding.window.id }.contains { $0.frame.contains(center) }
        }
    }

    private static func trim(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location, end = range.location + range.length
        let skip = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "=:\"'<>,"))
        while start < end, let scalar = UnicodeScalar(text.character(at: start)), skip.contains(scalar) { start += 1 }
        while end > start, let scalar = UnicodeScalar(text.character(at: end - 1)), skip.contains(scalar) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private func apply(_ found: [Finding], started: Date, sharing: Bool) {
        findings = Dictionary(found.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        windowOrigins = Dictionary(found.map { ($0.window.id, $0.window.frame.origin) }, uniquingKeysWith: { first, _ in first })
        let shown = findings.filter { !released.contains($0.key) }
        covers = covers.filter { $0.value.at > started }
        Task {
            await shields.prepare(shownRects())
            await MainActor.run {
                let kinds = Dictionary(grouping: shown.values, by: \.kind).mapValues(\.count)
                self.log.append(Event(event: sharing ? "shielded" : "prearmed", windows: Set(found.map(\.window.id)).count, shields: shown.count, kinds: kinds,
                                      milliseconds: Int(Date().timeIntervalSince(started) * 1000)))
                if sharing, let at = self.sharedAt, Date().timeIntervalSince(at) < 10 { self.announce(kinds) }
                self.scanning = false
                if self.pending { self.pending = false; self.scheduleScan() }
                self.review()
            }
        }
    }

    private func shownRects() -> [String: CGRect] {
        findings.filter { !released.contains($0.key) }.mapValues(\.rect).merging(covers.mapValues(\.rect)) { finding, _ in finding }
    }

    private func review() {
        let fresh = findings.values.filter { !asked.contains($0.key) && $0.kind != "password_field" }
        guard !fresh.isEmpty else { return }
        fresh.forEach { asked.insert($0.key) }
        let candidates = fresh.enumerated().map { $0.element.candidate($0.offset) }
        let started = Date()
        Task {
            do {
                let release = try await policy.release(candidates)
                await MainActor.run {
                    let keys = release.compactMap { fresh.indices.contains($0) ? fresh[$0].key : nil }
                    self.released.formUnion(keys)
                    self.shields.drop(keys)
                    self.log.append(Event(event: "reviewed", shields: candidates.count, released: keys.count, milliseconds: Int(Date().timeIntervalSince(started) * 1000),
                                          detail: keys.compactMap { self.findings[$0]?.kind }.joined(separator: ",")))
                }
            } catch {
                await MainActor.run {
                    fresh.forEach { self.asked.remove($0.key) }
                    self.log.append(Event(event: "review-failed", detail: error.localizedDescription))
                }
            }
        }
    }

    private func announce(_ kinds: [String: Int]) {
        let total = kinds.values.reduce(0, +)
        guard total > 0 else { return }
        let words = kinds.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key.replacingOccurrences(of: "private_", with: "").replacingOccurrences(of: "_", with: " "))" }
        notch.show(NotchMessage(text: "You're sharing your screen. I'm hiding \(total) private thing\(total == 1 ? "" : "s") from viewers: \(words.joined(separator: ", ")).", choices: [
            NotchChoice(label: "OK", isPrimary: true) { [weak self] in self?.notch.rest() },
        ]))
    }

    private func observe(_ pid: pid_t) {
        guard pid != observedPid, pid != getpid() else { return }
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        observedPid = pid
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            Unmanaged<StreamGuard>.fromOpaque(refcon).takeUnretainedValue().changed(element, notification as String)
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXValueChangedNotification, kAXFocusedWindowChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                     kAXFocusedUIElementChangedNotification, kAXTitleChangedNotification, kAXSelectedTextChangedNotification] {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    private func changed(_ element: AXUIElement, _ notification: String) {
        if notification == kAXWindowMovedNotification, let id = WindowServer.windowId(of: element), let old = windowOrigins[id],
           let position = Accessibility.attribute(kAXPositionAttribute, of: element) {
            var origin = CGPoint.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
            shields.move(by: CGPoint(x: origin.x - old.x, y: origin.y - old.y), keys: findings.values.filter { $0.window.id == id }.map(\.key))
            windowOrigins[id] = origin
        }
        scheduleScan()
    }
}
