import CoreGraphics
import Foundation

final class ShareWatcher {
    var onChange: ((Bool) -> Void)?
    var onWindowCreated: ((CGWindowID) -> Void)?
    private(set) var isSharing = false
    private var timer: Timer?
    private static weak var current: ShareWatcher?
    private typealias Present = @convention(c) () -> Bool
    private typealias Callback = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
    private typealias Register = @convention(c) (Int32, Callback, UInt32, UnsafeMutableRawPointer?) -> Int32
    private typealias Connection = @convention(c) () -> Int32
    private static let present: Present? = symbol("SLSIsScreenWatcherPresent") ?? symbol("CGSIsScreenWatcherPresent")

    var available: Bool { Self.present != nil }

    func start() {
        Self.current = self
        if let register: Register = Self.symbol("SLSRegisterConnectionNotifyProc"), let connection: Connection = Self.symbol("SLSMainConnectionID") {
            let callback: Callback = { _, _, _, _, _ in DispatchQueue.main.async { ShareWatcher.current?.check() } }
            for event: UInt32 in [1502, 1503] { _ = register(connection(), callback, event, nil) }
            let created: Callback = { _, data, length, _, _ in
                guard let data, length >= 12 else { return }
                let id = data.load(fromByteOffset: 8, as: CGWindowID.self)
                DispatchQueue.main.async { ShareWatcher.current?.onWindowCreated?(id) }
            }
            _ = register(connection(), created, 1325, nil)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.check() }
        check()
    }

    private func check() {
        let now = Self.present?() ?? false
        guard now != isSharing else { return }
        isSharing = now
        onChange?(now)
    }

    private static func symbol<T>(_ name: String) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) }
    }
}
