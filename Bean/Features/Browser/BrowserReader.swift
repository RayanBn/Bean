import ApplicationServices
import Foundation

struct BrowserPage: Codable, Equatable {
    let url: URL
    let title: String?
    let host: String
    let isSearch: Bool
    let searchQuery: String?
}

enum BrowserReader {
    static let bundleIds: Set<String> = ["company.thebrowser.Browser", "com.apple.Safari", "com.google.Chrome"]

    private static let mailHosts = ["mail.google.com", "gmail.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com", "outlook.com", "mail.proton.me", "mail.protonmail.com", "mail.yahoo.com", "fastmail.com"]
    private static let leafRoles: Set<String> = [kAXListRole, kAXButtonRole, kAXStaticTextRole, kAXScrollBarRole, kAXImageRole, kAXMenuButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXOutlineRole, kAXTableRole, kAXTextFieldRole]
    private static let nodeLimit = 300
    private static let timeout: Float = 0.1

    static func current(bundleId: String, pid: pid_t) -> BrowserPage? {
        guard bundleIds.contains(bundleId) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let window = Accessibility.focusedWindow(of: pid) else { return nil }
        let found = focusedWebArea(app: app, window: window) ?? search(window)
        guard let url = found.webArea.flatMap({ Accessibility.attribute("AXURL", of: $0) as? URL }) ?? found.addressBar.flatMap(addressBarURL),
              let host = url.host?.lowercased(), !isMail(url, host: host) else { return nil }
        let title = [found.webArea.flatMap { Accessibility.attribute(kAXTitleAttribute, of: $0) as? String }, Accessibility.attribute(kAXTitleAttribute, of: window) as? String]
            .compactMap { $0 }.first { !$0.isEmpty }
        let query = searchQuery(url: url, host: host, title: title)
        return BrowserPage(url: url, title: title, host: host, isSearch: query != nil, searchQuery: query)
    }

    private static func focusedWebArea(app: AXUIElement, window: AXUIElement) -> (webArea: AXUIElement?, addressBar: AXUIElement?)? {
        guard let focused = Accessibility.attribute(kAXFocusedUIElementAttribute, of: app) else { return nil }
        var element = focused as! AXUIElement
        var outermost: AXUIElement?
        for _ in 0..<60 {
            if CFEqual(element, window) { break }
            if role(of: element) == "AXWebArea" { outermost = element }
            guard let parent = Accessibility.attribute(kAXParentAttribute, of: element) else { return nil }
            element = parent as! AXUIElement
        }
        guard CFEqual(element, window), let outermost else { return nil }
        return (outermost, nil)
    }

    private static func search(_ window: AXUIElement) -> (webArea: AXUIElement?, addressBar: AXUIElement?) {
        var queue = [window], index = 0
        var addressBar: AXUIElement?
        while index < queue.count, index < nodeLimit {
            let element = queue[index]
            index += 1
            let role = role(of: element)
            if role == "AXWebArea" { return (element, nil) }
            if role == kAXTextFieldRole, addressBar == nil, isAddressBar(element) { addressBar = element }
            if leafRoles.contains(role) { continue }
            queue += Accessibility.attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
        }
        return (nil, addressBar)
    }

    private static func role(of element: AXUIElement) -> String {
        Accessibility.attribute(kAXRoleAttribute, of: element) as? String ?? ""
    }

    private static func isAddressBar(_ element: AXUIElement) -> Bool {
        let description = (Accessibility.attribute(kAXDescriptionAttribute, of: element) as? String ?? "").lowercased()
        return description.contains("address") || description.contains("adresse")
    }

    private static func addressBarURL(_ element: AXUIElement) -> URL? {
        guard let text = Accessibility.attribute(kAXValueAttribute, of: element) as? String, !text.contains(" "), text.contains(".") else { return nil }
        return URL(string: text.contains("://") ? text : "https://" + text)
    }

    private static func isMail(_ url: URL, host: String) -> Bool {
        mailHosts.contains { host == $0 || host.hasSuffix("." + $0) } || (host.hasSuffix("icloud.com") && url.path.hasPrefix("/mail"))
    }

    static func searchQuery(url: URL, host: String, title: String?) -> String? {
        let path = url.path
        switch true {
        case host.contains("google.") && path == "/search",
             host.hasSuffix("duckduckgo.com"),
             host.hasSuffix("bing.com") && path == "/search",
             host == "github.com" && path.hasSuffix("/search"),
             host.hasSuffix("stackoverflow.com") && path == "/search":
            return parameter("q", in: url)
        case host.hasSuffix("stackoverflow.com") && path.hasPrefix("/questions/"):
            let parts = path.split(separator: "/")
            guard parts.count >= 2, parts[1].allSatisfy(\.isNumber) else { return nil }
            return questionTitle(title) ?? (parts.count >= 3 ? parts[2].replacingOccurrences(of: "-", with: " ") : nil)
        default:
            return nil
        }
    }

    private static func parameter(_ name: String, in url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        let value = components.queryItems?.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
    }

    private static func questionTitle(_ title: String?) -> String? {
        guard var title, title.hasSuffix(" - Stack Overflow") else { return nil }
        title.removeLast(" - Stack Overflow".count)
        if let dash = title.range(of: " - "), !title[..<dash.lowerBound].contains(" ") {
            title = String(title[dash.upperBound...])
        }
        return title.isEmpty ? nil : title
    }
}
