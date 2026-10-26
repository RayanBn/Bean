enum PresenceProbe {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--probe-presence") else { return false }
        let (state, timing) = Probe.measure { Presence.current() }
        print(timing)
        print(Probe.json(state))
        return true
    }
}
