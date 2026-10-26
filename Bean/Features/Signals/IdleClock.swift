import AppKit

final class IdleClock {
    private struct Waiter {
        let seconds: () -> TimeInterval
        let repeats: Bool
        let handler: (TimeInterval) -> Void
        var fired = false
    }

    private var waiters: [Waiter] = []
    private var returnHandlers: [(TimeInterval) -> Void] = []
    private var timer: Timer?
    private var monitor: Any?
    private var lastInput = Date()

    static func seconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func every(idleFor seconds: @escaping () -> TimeInterval, _ handler: @escaping (TimeInterval) -> Void) {
        waiters.append(Waiter(seconds: seconds, repeats: true, handler: handler))
        schedule()
    }

    func once(idleFor seconds: TimeInterval, _ handler: @escaping (TimeInterval) -> Void) {
        waiters.append(Waiter(seconds: { seconds }, repeats: false, handler: handler))
        schedule()
    }

    func onReturn(_ handler: @escaping (TimeInterval) -> Void) {
        returnHandlers.append(handler)
    }

    private func schedule() {
        timer?.invalidate()
        let idle = Self.seconds()
        if monitor == nil { lastInput = Date().addingTimeInterval(-idle) }
        for index in waiters.indices where !waiters[index].fired && idle >= waiters[index].seconds() {
            waiters[index].fired = true
            waiters[index].handler(idle)
        }
        waiters.removeAll { $0.fired && !$0.repeats }
        if waiters.contains(where: \.fired) { watchForReturn() }
        guard let next = waiters.filter({ !$0.fired }).map({ $0.seconds() - idle }).min() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(next, 0.2), repeats: false) { [weak self] _ in self?.schedule() }
    }

    private func watchForReturn() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged]) { [weak self] _ in
            self?.returned()
        }
    }

    private func returned() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let away = Date().timeIntervalSince(lastInput)
        for index in waiters.indices { waiters[index].fired = false }
        returnHandlers.forEach { $0(away) }
        schedule()
    }
}
