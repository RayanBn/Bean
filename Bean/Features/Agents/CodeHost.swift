import Foundation

// `gh` answers only for a host it is signed in to, and anywhere else pull request facts are unknown, which is not the same as none.
enum CodeHost {
    private static let lock = NSLock()
    private static var seen: [String: (at: Date, yes: Bool)] = [:]

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "") + "'"
    }

    static func answers(_ host: String) -> Bool {
        if let known = lock.withLock({ seen[host] }), Date().timeIntervalSince(known.at) < (known.yes ? 3600 : 60) { return known.yes }
        let yes = HiddenShell.run("gh auth status --hostname \(quoted(host))", timeout: 10).exit == 0
        lock.withLock { seen[host] = (Date(), yes) }
        return yes
    }
}

struct PullRequestLink {
    let url: String
    let host: String
    let repo: String
    let number: String

    init?(_ link: String) {
        guard let parsed = URL(string: link), let host = parsed.host else { return nil }
        let parts = parsed.pathComponents.filter { $0 != "/" }
        guard let pull = parts.firstIndex(of: "pull"), pull >= 2, parts.indices.contains(pull + 1) else { return nil }
        url = link
        self.host = host.lowercased()
        repo = "\(parts[pull - 2])/\(parts[pull - 1])"
        number = parts[pull + 1]
    }

    var view: String { "gh pr view \(CodeHost.quoted(url)) --repo \(CodeHost.quoted(repo))" }
}
