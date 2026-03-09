import Foundation

final class AudioSettingsStore {
    private let defaults: UserDefaults
    private let settingsKey = "audio_trim_settings_v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadDraftSettings() -> AudioToAudioSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AudioToAudioSettings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    func saveDraftSettings(_ settings: AudioToAudioSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        defaults.set(data, forKey: settingsKey)
    }
}
