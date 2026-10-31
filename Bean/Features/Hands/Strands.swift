import Foundation

enum Strands {
    struct Choice {
        let pick: String
        let confidence: Double
        let ranked: [String]
        let odds: [String: Double]
    }

    static var isOn: Bool { BeanSettings.shared.effectiveDecidesOnThisMac && StrandsServer.isAvailable }

    static func ask(state: String, questions: [String: [String: Any]]) async -> [String: [String: Any]]? {
        guard let endpoint = await StrandsServer.shared.ready() else { return nil }
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/systemone"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["state": state, "questions": questions])
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["answers"] as? [String: [String: Any]]
    }

    static func choose(state: String, question: String, options: [String: String]) async -> Choice? {
        guard let answer = await ask(state: state, questions: ["q": ["type": "choice", "instructions": question, "criteria": options]])?["q"],
              let pick = answer["choice"] as? String, let confidence = answer["confidence"] as? Double else { return nil }
        let odds = answer["probabilities"] as? [String: Double] ?? [:]
        return Choice(pick: pick, confidence: confidence, ranked: odds.keys.sorted { odds[$0, default: 0] > odds[$1, default: 0] }, odds: odds)
    }
}
