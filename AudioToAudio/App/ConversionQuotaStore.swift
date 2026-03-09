import Foundation

final class ConversionQuotaStore {
    static let dailyFreeLimit = 1

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let dayKey = "free_conversion_day_v1"
    private let countKey = "free_conversion_count_v1"

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    func canUseFreeConversionToday() -> Bool {
        usedFreeConversionsToday() < Self.dailyFreeLimit
    }

    func remainingFreeConversionsToday() -> Int {
        max(0, Self.dailyFreeLimit - usedFreeConversionsToday())
    }

    func recordFreeConversionToday() {
        let used = usedFreeConversionsToday()
        defaults.set(min(Self.dailyFreeLimit, used + 1), forKey: countKey)
    }

#if DEBUG
    func debugResetFreeConversionsToday() {
        let todayToken = token(for: Date())
        defaults.set(todayToken, forKey: dayKey)
        defaults.set(0, forKey: countKey)
    }
#endif

    private func usedFreeConversionsToday() -> Int {
        let todayToken = token(for: Date())
        let storedToken = defaults.string(forKey: dayKey)

        if storedToken != todayToken {
            defaults.set(todayToken, forKey: dayKey)
            defaults.set(0, forKey: countKey)
            return 0
        }

        return max(0, defaults.integer(forKey: countKey))
    }

    private func token(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
