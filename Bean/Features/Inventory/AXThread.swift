import Foundation

final class AXThread: Thread {
    private var loop: CFRunLoop?
    private let started = DispatchSemaphore(value: 0)

    override init() {
        super.init()
        name = "bean.ax"
        qualityOfService = .utility
        start()
        started.wait()
    }

    override func main() {
        loop = CFRunLoopGetCurrent()
        RunLoop.current.add(Port(), forMode: .default)
        started.signal()
        while !isCancelled { RunLoop.current.run(mode: .default, before: .distantFuture) }
    }

    var runLoop: CFRunLoop { loop! }

    func async(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
    }
}
