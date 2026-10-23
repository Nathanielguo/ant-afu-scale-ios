import Foundation
import CryptoKit

/// A weight match is a convenience filter, not proof of identity.
enum MeasurementOwnership {
    static func confirmationReason(weight: Double, baseline: Measurement?, profile: UserProfile,
                                   now: Date = Date()) -> String? {
        if profile.confirmEveryMeasurement { return "已开启每次确认，请确认这是你的测量。" }
        guard let baseline else { return "首次测量需要确认本人，确认后建立体重基线。" }
        guard now.timeIntervalSince(baseline.date) >= 0,
              now.timeIntervalSince(baseline.date) <= 30 * 24 * 3600 else {
            return "本人基线超过 30 天未更新，请重新确认。"
        }
        let difference = abs(weight - baseline.weightKg)
        if difference > profile.weightToleranceKg {
            return String(format: "与本人最近体重 %.2f kg 相差 %.2f kg，可能是他人的测量。", baseline.weightKg, difference)
        }
        return nil
    }

    static func isRepeated(_ candidate: Measurement, previous: Measurement?) -> Bool {
        guard let previous else { return false }
        let elapsed = candidate.date.timeIntervalSince(previous.date)
        return abs(elapsed) < 120 &&
            abs(candidate.weightKg - previous.weightKg) < 0.01 &&
            abs(candidate.impedance - previous.impedance) < 0.1
    }
}

/// Confirmed records awaiting HealthKit. Persist before starting a write so an app
/// interruption can be retried with the same HealthKit sync identifier.
enum HealthSyncQueue {
    private static let key = "pending_health_measurements"

    static func load(defaults: UserDefaults = .standard) -> [Measurement] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Measurement].self, from: data)) ?? []
    }

    static func enqueue(_ measurement: Measurement, defaults: UserDefaults = .standard) {
        var pending = load(defaults: defaults)
        guard !pending.contains(where: { $0.id == measurement.id }) else { return }
        pending.append(measurement)
        persist(pending, defaults: defaults)
    }

    static func markSynced(_ id: UUID, defaults: UserDefaults = .standard) {
        persist(load(defaults: defaults).filter { $0.id != id }, defaults: defaults)
    }

    private static func persist(_ pending: [Measurement], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Persistent identities for replayed history, including deliberately ignored
/// records. History packets have no person ID: ownership still needs filtering.
enum ScaleHistoryIdentity {
    static func id(peripheral: UUID, date: Date, weight: Double, impedance: Double) -> UUID {
        let key = "\(peripheral.uuidString)|\(Int(date.timeIntervalSince1970))|\(weight)|\(impedance)"
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func contains(_ id: UUID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: "processed_scale_history") ?? []).contains(id.uuidString)
    }

    static func remember(_ id: UUID) {
        var ids = UserDefaults.standard.stringArray(forKey: "processed_scale_history") ?? []
        guard !ids.contains(id.uuidString) else { return }
        ids.append(id.uuidString)
        UserDefaults.standard.set(ids, forKey: "processed_scale_history")
    }
}

/// Keep confirmed history locally even when it predates the dashboard baseline or
/// HealthKit synchronization is disabled.
enum ConfirmedMeasurements {
    static func load() -> [Measurement] {
        guard let data = UserDefaults.standard.data(forKey: "confirmed_measurements"),
              let records = try? JSONDecoder().decode([Measurement].self, from: data) else {
            return Measurement.loadLatest().map { [$0] } ?? []
        }
        return records
    }

    static func save(_ measurement: Measurement) {
        var records = load()
        guard !records.contains(where: { $0.id == measurement.id }) else { return }
        records.append(measurement)
        records.sort { $0.date > $1.date }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: "confirmed_measurements")
        }
    }
}
