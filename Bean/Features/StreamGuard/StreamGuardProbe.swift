import Foundation

enum StreamGuardProbe {
    static func runIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-privacy"), index + 1 < CommandLine.arguments.count else { return false }
        let start = Date()
        guard let model = try? PrivacyModel(directory: PrivacyModelStore.directory) else {
            print("privacy model missing in \(PrivacyModelStore.directory.path)")
            return true
        }
        print(String(format: "loaded %@ in %.0f ms", PrivacyModel.name, Date().timeIntervalSince(start) * 1000))
        let text = (try? String(contentsOfFile: CommandLine.arguments[index + 1], encoding: .utf8)) ?? ""
        var times: [Double] = []
        for line in text.split(separator: "\n").map(String.init) {
            let t = Date()
            let spans = (try? model.spans(in: line)) ?? []
            times.append(Date().timeIntervalSince(t) * 1000)
            let found = spans.map { "\($0.kind)=\((line as NSString).substring(with: $0.range))" }
            print((spans.isEmpty ? "     " : "HIT  ") + line.prefix(60) + "  " + found.joined(separator: " | "))
        }
        let t = Date()
        let whole = (try? model.spans(in: text)) ?? []
        print(String(format: "median %.0f ms per line; whole text (%d chars) %.0f ms, %d spans", times.sorted()[times.count / 2], text.count, Date().timeIntervalSince(t) * 1000, whole.count))
        return true
    }
}
