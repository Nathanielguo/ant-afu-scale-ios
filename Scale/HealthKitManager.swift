import Foundation
import HealthKit
import Combine

/// 把测量结果写入 Apple「健康」App。
@MainActor
final class HealthKitManager: ObservableObject {
    @Published private(set) var message: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var pendingCount = HealthSyncQueue.load().count

    func syncPending() async {
        pendingCount = HealthSyncQueue.load().count
        guard !isSyncing else { return }
        guard UserProfile.load().autoSyncHealth else {
            message = pendingCount > 0 ? "健康同步已暂停，\(pendingCount) 条待同步记录保留在本机" : nil
            return
        }
        guard pendingCount > 0 else { return }
        isSyncing = true
        message = "正在同步到 Apple 健康…"
        defer { isSyncing = false; pendingCount = HealthSyncQueue.load().count }
        do {
            try await requestAuthorization()
            while UserProfile.load().autoSyncHealth, let measurement = HealthSyncQueue.load().first {
                try await save(measurement)
                HealthSyncQueue.markSynced(measurement.id)
            }
            message = HealthSyncQueue.load().isEmpty ? "已同步到「健康」App" : "自动同步已暂停，待同步记录保留在本机"
        } catch {
            message = "同步未完成，记录已保留：\(error.localizedDescription)"
        }
    }

    private func syncError(_ message: String) -> NSError {
        NSError(domain: "Scale.HealthSync", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private let store = HKHealthStore()

    private let bodyMass = HKQuantityType(.bodyMass)
    private let bodyFat = HKQuantityType(.bodyFatPercentage)
    private let bmiType = HKQuantityType(.bodyMassIndex)
    private let leanMass = HKQuantityType(.leanBodyMass)

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// 请求写入权限（首次会弹系统授权页）。
    func requestAuthorization() async throws {
        guard isAvailable else { throw syncError("此设备无法使用 Apple 健康") }
        let types: Set = [bodyMass, bodyFat, bmiType, leanMass]
        try await store.requestAuthorization(toShare: types, read: [])
    }

    /// 写入一次测量：体重、体脂率、BMI、去脂体重。
    func save(_ m: Measurement) async throws {
        guard isAvailable else { throw syncError("此设备无法使用 Apple 健康") }
        let types = [bodyMass, bodyFat, bmiType, leanMass]
        guard types.allSatisfy({ store.authorizationStatus(for: $0) == .sharingAuthorized }) else {
            throw syncError("请在健康 App 中允许体重、体脂率、BMI 和去脂体重的写入权限后重试")
        }
        let date = m.date
        func metadata(for type: HKQuantityType) -> [String: Any] {
            [HKMetadataKeySyncIdentifier: "\(m.id.uuidString).\(type.identifier)",
             HKMetadataKeySyncVersion: 1]
        }
        var samples: [HKQuantitySample] = []

        samples.append(HKQuantitySample(
            type: bodyMass,
            quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: m.weightKg),
            start: date, end: date, metadata: metadata(for: bodyMass)))

        samples.append(HKQuantitySample(
            type: bodyFat,
            quantity: HKQuantity(unit: .percent(), doubleValue: m.bodyFatPercent / 100.0),
            start: date, end: date, metadata: metadata(for: bodyFat)))

        samples.append(HKQuantitySample(
            type: bmiType,
            quantity: HKQuantity(unit: .count(), doubleValue: m.bmi),
            start: date, end: date, metadata: metadata(for: bmiType)))

        samples.append(HKQuantitySample(
            type: leanMass,
            quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: m.leanBodyMassKg),
            start: date, end: date, metadata: metadata(for: leanMass)))

        try await store.save(samples)
    }
}
