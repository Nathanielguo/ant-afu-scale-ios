import Foundation

@main
struct SyncPolicyTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            checks += 1
        }
        let now = Date()
        let profile = UserProfile()
        func measurement(weight: Double = 70, age: TimeInterval = 0, impedance: Double = 500) -> Measurement {
            Measurement(id: UUID(), date: now.addingTimeInterval(-age), weightKg: weight,
                        impedance: impedance, bmi: 24, bodyFatPercent: 20, waterPercent: 55,
                        muscleRate: 70, bmr: 1600, leanBodyMassKg: 56)
        }
        let baseline = measurement()
        func reason(_ weight: Double, baseline: Measurement? = baseline, profile: UserProfile = profile) -> String? {
            MeasurementOwnership.confirmationReason(weight: weight, baseline: baseline, profile: profile, now: now)
        }
        check(reason(70, baseline: nil) != nil, "First measurement requires confirmation")
        check(reason(73) == nil, "Tolerance boundary accepted")
        check(reason(73.01) != nil, "Heavy outlier held")
        check(reason(66.99) != nil, "Light outlier held")
        check(reason(70, baseline: measurement(age: 31 * 86400)) != nil, "Stale baseline held")
        check(reason(70, baseline: measurement(age: -60)) != nil, "Future baseline held")
        var strict = profile
        strict.confirmEveryMeasurement = true
        check(reason(70, profile: strict) != nil, "Shared scale strict mode")
        check(MeasurementOwnership.isRepeated(measurement(), previous: baseline), "Duplicate packet")
        check(!MeasurementOwnership.isRepeated(measurement(), previous: measurement(age: 121)), "Later weighing accepted")
        check(!MeasurementOwnership.isRepeated(measurement(impedance: 510), previous: baseline), "Different impedance accepted")
        let oldProfile = try JSONDecoder().decode(UserProfile.self, from: Data(#"{"heightCm":180,"age":40,"isMale":false,"autoSyncHealth":false}"#.utf8))
        check(oldProfile.heightCm == 180 && !oldProfile.autoSyncHealth && oldProfile.autoConnect, "Profile migration preserves old fields")
        let badTolerance = try JSONDecoder().decode(UserProfile.self, from: Data(#"{"weightToleranceKg":100}"#.utf8))
        check(badTolerance.weightToleranceKg == 10, "Tolerance clamped")
        let suite = "ScaleSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        HealthSyncQueue.enqueue(baseline, defaults: defaults)
        HealthSyncQueue.enqueue(baseline, defaults: defaults)
        check(HealthSyncQueue.load(defaults: defaults).count == 1, "Queue deduplicates same ID")
        let restored = UserDefaults(suiteName: suite)!
        check(HealthSyncQueue.load(defaults: restored).first?.id == baseline.id, "Queue restores original ID")
        let second = measurement(weight: 71)
        HealthSyncQueue.enqueue(second, defaults: defaults)
        HealthSyncQueue.markSynced(baseline.id, defaults: defaults)
        check(HealthSyncQueue.load(defaults: defaults).map(\.id) == [second.id], "Success only removes matching record")
        HealthSyncQueue.markSynced(second.id, defaults: defaults)
        check(HealthSyncQueue.load(defaults: defaults).isEmpty, "Queue drains")
        check(Scale27.decode([0xAC]) == nil, "Truncated packet ignored")
        check(Scale27.encodeUserInfo(deviceType: 0x29, profile: profile).count == 20, "Profile packet length")
        func historyPacket(device: UInt8 = 41, type: UInt8 = 2, timestamp: UInt32 = UInt32(now.timeIntervalSince1970)) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 20)
            bytes[0] = 0xAC; bytes[1] = device
            bytes[2] = type
            let timeOffset = device == 42 ? 2 : 3
            let weightOffset = device == 42 ? 6 : 7
            for j in 0..<4 { bytes[timeOffset + j] = UInt8(truncatingIfNeeded: timestamp >> (24 - 8 * j)) }
            let encoded: UInt32 = 70_000
            for j in 0..<4 { bytes[weightOffset + j] = UInt8(truncatingIfNeeded: encoded >> (24 - 8 * j)) }
            let adcOffset: Int
            if device == 42 { adcOffset = 10 }
            else if type == 0 { bytes[14] = 1; adcOffset = 15 }
            else if type == 2 { bytes[12] = 1; adcOffset = 13 }
            else { adcOffset = 11 }
            bytes[adcOffset] = 1; bytes[adcOffset + 1] = 244
            if device != 42 && type == 1 { bytes[adcOffset + 2] = 1; bytes[adcOffset + 3] = 244 }
            bytes[18] = 216
            bytes[19] = UInt8(bytes[2..<19].reduce(0) { $0 + Int($1) } & 0x1F)
            return bytes
        }
        for variant in [(UInt8(41), UInt8(0)), (41, 1), (41, 2), (42, 0)] {
            let packet = historyPacket(device: variant.0, type: variant.1)
            guard case .history(let weight, let impedances, let date) = Scale27.decode(packet) else {
                preconditionFailure("History variant rejected")
            }
            check(weight == 70 && impedances.first == 500 && abs(date.timeIntervalSince(now)) < 1, "History date/weight/impedance preserved")
        }
        var corrupt = historyPacket()
        corrupt[7] ^= 1
        check(Scale27.decode(corrupt) == nil, "Checksum corruption rejected")
        check(Scale27.decode(historyPacket(timestamp: 0)) == nil, "Missing historical timestamp rejected")
        check(Scale27.decode(historyPacket(timestamp: UInt32(now.timeIntervalSince1970 + 3600))) == nil, "Future historical timestamp rejected")
        var badCount = historyPacket()
        badCount[12] = 255
        badCount[19] = UInt8(badCount[2..<19].reduce(0) { $0 + Int($1) } & 0x1F)
        check(Scale27.decode(badCount) == nil, "History count cannot read out of bounds")
        let peripheral = UUID()
        let historicalID = ScaleHistoryIdentity.id(peripheral: peripheral, date: now, weight: 70, impedance: 500)
        check(historicalID == ScaleHistoryIdentity.id(peripheral: peripheral, date: now, weight: 70, impedance: 500), "Stable historical identifier")
        check(historicalID != ScaleHistoryIdentity.id(peripheral: UUID(), date: now, weight: 70, impedance: 500), "Separate scales have separate identifiers")
        let historicalResult = BodyComposition.calculate(weightKg: 70, impedance: 500, profile: profile, id: historicalID, date: now.addingTimeInterval(-86400))
        check(historicalResult.id == historicalID && historicalResult.date == now.addingTimeInterval(-86400), "Calculation retains historical identity/time")
        print("Passed \(checks) sync policy / migration / queue / protocol checks")
    }
}
