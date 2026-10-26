import AppKit
import CoreAudio
import IOKit.ps

enum SystemReader {
    static func apps(tracked: [CGWindowID: TrackedWindow], focused: [pid_t: CGWindowID]) -> (apps: [InventoryApp], background: Int) {
        var windows = windowsByPid()
        let spaces = WindowServer.spaces(of: windows.values.flatMap { $0.map(\.id) })
        for (pid, list) in windows {
            windows[pid] = list.map { window in
                var window = window
                window.space = spaces[window.id]
                if let known = tracked[window.id] {
                    window.seenByAccessibility = true
                    window.isMinimized = known.minimized
                }
                window.isFocused = focused[pid] == window.id
                return window
            }
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var background = 0
        let apps: [InventoryApp] = NSWorkspace.shared.runningApplications.compactMap { app in
            let kind: InventoryApp.Kind
            switch app.activationPolicy {
            case .regular: kind = .dock
            case .accessory: kind = .menuBar
            default: kind = .background
            }
            if kind != .dock, app.bundleIdentifier?.hasPrefix("com.apple.") != false, windows[app.processIdentifier] == nil {
                background += 1
                return nil
            }
            return InventoryApp(
                name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)", bundleId: app.bundleIdentifier, pid: app.processIdentifier,
                kind: kind, path: app.bundleURL?.path, launchedAt: app.launchDate, isActive: app.processIdentifier == frontmost, isHidden: app.isHidden,
                windows: windows[app.processIdentifier] ?? []
            )
        }
        return (apps.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }, background)
    }

    static func windowsByPid() -> [pid_t: [InventoryWindow]] {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var result: [pid_t: [InventoryWindow]] = [:]
        for info in list {
            guard info[kCGWindowLayer as String] as? Int == 0, let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: Double],
                  let width = bounds["Width"], let height = bounds["Height"], width >= 120, height >= 80 else { continue }
            let title = info[kCGWindowName as String] as? String ?? ""
            let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            if title.isEmpty, !onScreen { continue }
            result[pid, default: []].append(InventoryWindow(id: id, title: title, onScreen: onScreen, x: Int(bounds["X"] ?? 0), y: Int(bounds["Y"] ?? 0), width: Int(width), height: Int(height)))
        }
        return result
    }

    static func processes() -> [InventoryProcess] {
        let output = HiddenShell.capture("/bin/ps", ["-U", NSUserName(), "-o", "pcpu=,rss=,comm="], timeout: 4) ?? ""
        var groups: [String: (count: Int, cpu: Double, rss: Int, example: String)] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let cpu = Double(parts[0]), let rss = Int(parts[1]) else { continue }
            let path = String(parts[2])
            if path.contains(".app/") || path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") || path.contains("/CoreSimulator/") { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let current = groups[name] ?? (0, 0, 0, path)
            groups[name] = (current.count + 1, current.cpu + cpu, current.rss + rss, current.example)
        }
        return groups.map { InventoryProcess(name: $0.key, count: $0.value.count, cpu: ($0.value.cpu * 10).rounded() / 10, memoryMB: $0.value.rss / 1024, example: $0.value.example) }
            .sorted { $0.memoryMB > $1.memoryMB }
    }

    static func displays() -> [InventoryDisplay] {
        NSScreen.screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return InventoryDisplay(name: screen.localizedName, width: Int(screen.frame.width), height: Int(screen.frame.height), isMain: screen == NSScreen.main, isBuiltIn: CGDisplayIsBuiltin(id) != 0)
        }
    }

    static func battery() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              let capacity = description[kIOPSCurrentCapacityKey] as? Int else { return nil }
        let charging = description[kIOPSIsChargingKey] as? Bool == true
        let plugged = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        return "\(capacity) %\(charging ? ", charging" : plugged ? ", plugged in" : ", on battery")"
    }

    static func audioOutput() -> (name: String?, volume: Int?) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return (nil, nil) }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        let deviceName = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr ? name?.takeRetainedValue() as String? : nil
        var volume = Float32(0)
        size = UInt32(MemoryLayout<Float32>.size)
        let level = [kAudioObjectPropertyElementMain, 1].lazy.compactMap { element -> Int? in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr ? Int((volume * 100).rounded()) : nil
        }.first
        return (deviceName, level)
    }

    static func mountedVolumes() -> [String] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []).map(\.path)
    }

    static var darkMode: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
