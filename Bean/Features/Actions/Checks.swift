import AppKit

enum Checks {
    @MainActor
    static func passes(_ check: Check, bundleId: String? = nil) async -> Bool {
        switch check.kind {
        case .all: return await all(check.checks ?? [], bundleId)
        case .any:
            for item in check.checks ?? [] where await passes(item, bundleId: bundleId) { return true }
            return false
        case .shellExit:
            let command = check.value ?? "false"
            let result = await Task.detached { HiddenShell.run(command, timeout: 10) }.value
            return result.exit == (check.exit ?? 0)
        case .present, .absent:
            guard let target = check.target else { return false }
            var locator = target
            if locator.bundleId == nil { locator.bundleId = bundleId }
            let found: Bool
            if case .found = AXTree.resolve(locator) { found = true } else { found = AXTree.root(for: locator).map { AXTree.nodes(in: $0.1).contains { $0.matches(locator) } } ?? false }
            return found == (check.kind == .present)
        case .textAppears, .titleContains, .urlMatches:
            guard let value = check.value, let snapshot = AXSnapshot.capture(check.target?.bundleId ?? bundleId) else { return false }
            switch check.kind {
            case .titleContains: return snapshot.title?.localizedCaseInsensitiveContains(value) ?? false
            case .textAppears: return snapshot.lines.contains { $0.localizedCaseInsensitiveContains(value) }
            default:
                guard let regex = try? NSRegularExpression(pattern: value) else { return false }
                return snapshot.urls.contains { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            }
        }
    }

    @MainActor
    private static func all(_ checks: [Check], _ bundleId: String?) async -> Bool {
        for item in checks where !(await passes(item, bundleId: bundleId)) { return false }
        return true
    }
}
