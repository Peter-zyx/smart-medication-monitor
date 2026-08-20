import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: self == .english ? "en" : "zh-Hans")
    }

    var displayName: String {
        self == .english ? "English" : "简体中文"
    }

    func text(_ english: String, _ chinese: String) -> String {
        self == .english ? english : chinese
    }
}

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: storageKey) }
    }
    @Published var usePhoneCamera: Bool {
        didSet { defaults.set(usePhoneCamera, forKey: phoneCameraStorageKey) }
    }

    private let defaults: UserDefaults
    private let storageKey = "medbox.app-language.v1"
    private let phoneCameraStorageKey = "medbox.use-phone-camera.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: storageKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .english
        usePhoneCamera = defaults.object(forKey: phoneCameraStorageKey) as? Bool ?? true
    }

    func text(_ english: String, _ chinese: String) -> String {
        language.text(english, chinese)
    }
}
