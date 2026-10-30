import Foundation

enum ClaudeTranscripts {
    struct LiveSession: Codable {
        let pid: Int32
        let sessionId: String
        let cwd: String
        var kind: String?
        var entrypoint: String?
        var status: String?
        var name: String?
    }

    struct Past {
        var projects = 0, projectsSkipped = 0
        var transcripts = 0, transcriptsSkipped = 0
        var messages: [String] = []
    }

    private struct Skip: Encodable {
        var at = Date()
        let what: String
        let path: String
        let term: String
    }

    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    private static let skips = JSONLog(name: "transcript-skips")
    private static let secrets = try! NSRegularExpression(pattern: #"(sk-|gho_|ghp_|xox[bp]-|AKIA|Bearer\s)[A-Za-z0-9_\-]{8,}"#)

    static func live(root: URL = home.appendingPathComponent("sessions")) -> [LiveSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file -> LiveSession? in
            guard let session = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode(LiveSession.self, from: $0) }), kill(session.pid, 0) == 0 else { return nil }
            if let term = OffLimits.match("\(session.cwd) \(session.name ?? "")") {
                skips.append(Skip(what: "live", path: file.lastPathComponent, term: term))
                return nil
            }
            return session
        }
    }

    static func pastMessages(root: URL = home.appendingPathComponent("projects"), limit: Int = 200) -> Past {
        var past = Past()
        let projects = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for project in projects {
            past.projects += 1
            if let term = OffLimits.match(project.lastPathComponent) {
                past.projectsSkipped += 1
                skips.append(Skip(what: "project", path: project.lastPathComponent, term: term))
                continue
            }
            let files = ((try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "jsonl" }
            for file in files {
                past.transcripts += 1
                guard let data = try? Data(contentsOf: file) else { continue }
                if let term = offLimits(in: data) {
                    past.transcriptsSkipped += 1
                    skips.append(Skip(what: "transcript", path: project.lastPathComponent + "/" + file.lastPathComponent, term: term))
                    continue
                }
                past.messages += typed(String(decoding: data, as: UTF8.self))
            }
        }
        past.messages = Array(past.messages.suffix(limit))
        return past
    }

    private static func offLimits(in data: Data) -> String? {
        var compact = Data(capacity: data.count)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                let lower = byte >= 65 && byte <= 90 ? byte + 32 : byte
                if (lower >= 97 && lower <= 122) || (lower >= 48 && lower <= 57) || lower == 47 { compact.append(lower) }
            }
        }
        return OffLimits.terms.first { term in
            let needle = Data(term.utf8.filter { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 47 })
            return !needle.isEmpty && compact.range(of: needle) != nil
        }
    }

    private static func typed(_ transcript: String) -> [String] {
        transcript.split(separator: "\n").compactMap { line in
            guard line.contains("\"type\":\"user\""),
                  let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  row["type"] as? String == "user", row["isMeta"] as? Bool != true, row["isSidechain"] as? Bool != true,
                  let content = (row["message"] as? [String: Any])?["content"] as? String else { return nil }
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("Caveat:"),
                  secrets.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil else { return nil }
            return String(text.prefix(500))
        }
    }
}
