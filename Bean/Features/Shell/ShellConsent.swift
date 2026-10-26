import Foundation

enum ShellConsent {
    static func askIfNeeded(notch: NotchController, logTo log: URL, then start: @escaping () -> Void) {
        if ShellHooks.isInstalled() {
            try? ShellHooks.install(logTo: log)
            start()
            return
        }
        guard !UserDefaults.standard.bool(forKey: ShellHooks.declinedKey) else { return }
        notch.show(NotchMessage(
            text: "Want me to notice when a terminal command keeps failing, in every terminal? I'll add one line to ~/.zshrc. Commands stay on this Mac.",
            choices: [
                NotchChoice(label: "Not now", isPrimary: false) {
                    UserDefaults.standard.set(true, forKey: ShellHooks.declinedKey)
                    notch.rest()
                },
                NotchChoice(label: "Allow", isPrimary: true) {
                    do {
                        try ShellHooks.install(logTo: log)
                        notch.done("New terminals")
                        start()
                    } catch {
                        notch.show(NotchMessage(text: "Could not update ~/.zshrc: \(error.localizedDescription)", choices: []))
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { notch.rest() }
                },
            ]
        ))
    }
}
