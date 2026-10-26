import CoreGraphics
import Foundation

struct InventoryWindow: Codable, Equatable {
    let id: CGWindowID
    let title: String
    let onScreen: Bool
    let x: Int, y: Int, width: Int, height: Int
    var space: Int?
    var isFocused = false
    var isMinimized = false
    var seenByAccessibility = false
}

struct InventoryApp: Codable, Equatable {
    enum Kind: String, Codable { case dock, menuBar, background }

    let name: String
    let bundleId: String?
    let pid: Int32
    let kind: Kind
    let path: String?
    let launchedAt: Date?
    var isActive: Bool
    var isHidden: Bool
    var windows: [InventoryWindow]
}

struct InventoryProcess: Codable, Equatable {
    let name: String
    let count: Int
    let cpu: Double
    let memoryMB: Int
    let example: String
}

struct InventoryDisplay: Codable, Equatable {
    let name: String
    let width: Int, height: Int
    let isMain: Bool
    let isBuiltIn: Bool
}

struct InventorySystem: Codable, Equatable {
    var host: String
    var user: String
    var os: String
    var uptimeHours: Double
    var darkMode: Bool
    var locked: Bool
    var asleep: Bool
    var idleSeconds: Double
    var battery: String?
    var network: String?
    var audioOutput: String?
    var volume: Int?
    var micInUse: Bool
    var cameraInUse: Bool
    var displays: [InventoryDisplay]
    var mountedVolumes: [String]
    var spaceChanges: Int
    var activeSpace: Int
}

struct Inventory: Codable {
    let at: Date
    var system: InventorySystem
    let apps: [InventoryApp]
    let backgroundApps: Int
    let processes: [InventoryProcess]
    let trackedProcesses: [TrackedProcess]
    let focusedText: WindowText?
    let tabs: [BrowserTab]
    let agents: [AgentSession]
    let recentFiles: [String]
    let ports: [ListeningPort]
    let commands: [ShellCommand]
}

struct InventoryEvent: Codable {
    let at: Date
    let event: String
    var app: String? = nil
    var bundleId: String? = nil
    var detail: String? = nil
    var pid: pid_t? = nil
    var windowId: CGWindowID? = nil
}
