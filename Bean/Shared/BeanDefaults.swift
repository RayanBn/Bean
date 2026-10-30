import Foundation

enum BeanDefaults {
    static let shared: UserDefaults = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BEAN_DATA_DIR"] != nil else { return .standard }
        return UserDefaults(suiteName: "dev.rayanbn.Bean.test.\(environment["BEAN_RUN_ID"] ?? "local")")!
    }()
}
