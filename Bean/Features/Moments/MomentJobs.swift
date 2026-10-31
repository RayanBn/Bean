import AppKit

// One row per kind of work Bean has an answer for. Standing answers and the trust ladder are the same record, so they cannot disagree.
struct MomentJob: Codable, Equatable {
    enum Step: Int, Codable, Comparable {
        case silent, offer, keepDoing, aloneSaying, aloneQuiet
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
        var lower: Step { Step(rawValue: rawValue - 1) ?? .silent }
    }

    enum Move: Equatable {
        case asked, yes, keepDoing, cleanRun, notNow, ignored, modelIgnored, never
        case undone(String?)
    }

    var bundle: String
    var words: [String]
    var hearing = false
    var step: Step = .silent
    var never = false
    var quietUntil: Date?
    var ignored = 0
    var cleanRuns = 0
    var yeses = 0
    var agent: UUID?
    var corrections: [String] = []
    var saidBy = "code"

    func covers(_ moment: Moment, hearing wanted: Bool) -> Bool {
        hearing == wanted && bundle == Self.bundle(of: moment) && Set(words).isSubset(of: moment.titleWords)
    }

    static func bundle(of moment: Moment) -> String { moment.bundleId.flatMap { $0.isEmpty ? nil : $0 } ?? moment.app ?? "" }

    func moved(_ move: Move, now: Date, rules: MomentRules) -> MomentJob {
        var job = self
        switch move {
        case .asked: job.step = max(job.step, .offer)
        case .yes:
            job.step = max(job.step, .keepDoing)
            job.ignored = 0
            job.yeses += 1
            job.quietUntil = nil
            job.saidBy = "person"
        case .keepDoing:
            job.step = max(job.step, .aloneSaying)
            job.saidBy = "person"
        case .cleanRun:
            guard job.step == .aloneSaying else { break }
            job.cleanRuns += 1
            if job.cleanRuns >= rules.cleanRunsForQuiet { job.step = .aloneQuiet }
        case .notNow:
            job.quietUntil = now.addingTimeInterval(rules.notNowDays * 86400)
            job.ignored = 0
            job.saidBy = "person"
        case .ignored:
            job.ignored += 1
            if job.ignored >= rules.ignoredCountsAsNotNow {
                job.quietUntil = now.addingTimeInterval(rules.notNowDays * 86400)
                job.ignored = 0
            }
        case .modelIgnored:
            job.quietUntil = now.addingTimeInterval(rules.ignoredDays * 86400)
            job.saidBy = "model"
        case .never:
            job.never = true
            job.saidBy = "person"
        case let .undone(words):
            job.step = job.step.lower
            job.cleanRuns = 0
            if let words, !words.isEmpty { job.corrections.append(words) }
            job.saidBy = "person"
        }
        return job
    }
}

enum Standing: Equatable {
    case stop(String)
    case goOn(MomentJob?)
}

// A model's key may only narrow an answer to words the title really holds, since what a window says never counts as a yes.
enum MomentKey {
    static func words(modelKey: String, moment: Moment) -> [String] {
        let title = moment.titleWords
        let said = Moment.words(modelKey).intersection(title)
        return (said.isEmpty ? title : said).sorted()
    }
}

@MainActor
final class MomentJobs {
    private let file: URL
    let rules: MomentRules
    private(set) var all: [MomentJob]

    init(file: URL = JSONLog.directory.appendingPathComponent("standing.json"), rules: MomentRules = .starting) {
        self.file = file
        self.rules = rules
        all = (try? Data(contentsOf: file)).flatMap { try? Self.decoder.decode([MomentJob].self, from: $0) } ?? []
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(all).write(to: file, options: .atomic)
    }

    func standing(for moment: Moment, hearing: Bool = false, now: Date = Date()) -> Standing {
        let covering = all.filter { $0.covers(moment, hearing: hearing) }
        if covering.contains(where: \.never) { return .stop("never here") }
        if covering.contains(where: { ($0.quietUntil ?? .distantPast) > now }) { return .stop("not now") }
        return .goOn(covering.max { $0.words.count < $1.words.count })
    }

    @discardableResult
    func move(_ move: MomentJob.Move, moment: Moment, words: [String], hearing: Bool = false, agent: UUID? = nil, now: Date = Date()) -> MomentJob {
        let bundle = MomentJob.bundle(of: moment)
        let index = all.firstIndex { $0.bundle == bundle && $0.words == words && $0.hearing == hearing }
        var job = (index.map { all[$0] } ?? MomentJob(bundle: bundle, words: words, hearing: hearing)).moved(move, now: now, rules: rules)
        if let agent { job.agent = agent }
        if let index { all[index] = job } else { all.append(job) }
        save()
        return job
    }

    func never(moment: Moment, hearing: Bool = false) {
        move(.never, moment: moment, words: [], hearing: hearing)
    }

    func job(ofAgent id: UUID) -> Int? { all.firstIndex { $0.agent == id } }

    func undone(agent id: UUID, words: String?, now: Date = Date()) {
        guard let index = job(ofAgent: id) else { return }
        all[index] = all[index].moved(.undone(words), now: now, rules: rules)
        all[index].agent = nil
        save()
    }

    func corrected(agent id: UUID, words: String, now: Date = Date()) {
        guard let index = job(ofAgent: id) else { return }
        all[index] = all[index].moved(.undone(words), now: now, rules: rules)
        save()
    }

    var forCard: String {
        let shown = all.filter { !$0.hearing }.suffix(12).map { job in
            let scope = job.words.isEmpty ? job.bundle : "\(job.bundle): \(job.words.joined(separator: " "))"
            let corrected = job.corrections.last.map { ", corrected: \($0)" } ?? ""
            return "- \(scope): \(job.never ? "never" : String(describing: job.step))\(corrected)"
        }
        return shown.isEmpty ? "nothing yet" : shown.joined(separator: "\n")
    }
}

// A reversible safety rule in code: these apps form no moment, and no title of theirs leaves the Mac, until the person places an agent by hand.
enum SealedApps {
    private static let lock = NSLock()
    private static var known: [String: Bool] = [:]

    static func contains(bundleId: String?, app: String?, rules: MomentRules = .starting) -> Bool {
        let name = "\(bundleId ?? "") \(app ?? "")".lowercased()
        if rules.sealedNames.contains(where: name.contains) { return true }
        guard let bundleId, !bundleId.isEmpty else { return false }
        if let found = lock.withLock({ known[bundleId] }) { return found }
        let category = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).flatMap { Bundle(url: $0)?.infoDictionary?["LSApplicationCategoryType"] as? String }
        let found = category.map(rules.sealedCategories.contains) ?? false
        lock.withLock { known[bundleId] = found }
        return found
    }
}
