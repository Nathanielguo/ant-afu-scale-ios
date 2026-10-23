import Foundation

/// AFU / 沃莱（Welland）体脂秤的 "Scale27" 协议解析。
/// 移植自 ant-afu-welland-scale 项目的 protocol.py。
/// 每一包 20 字节，包头 0xAC；第 18 字节是包类型：213=体重，214=阻抗(ADC)。
enum Scale27 {

    /// 一包解析结果
    enum Packet {
        case weight(kg: Double, stable: Bool)          // 体重包
        case history(kg: Double, impedances: [Double], date: Date)
        case adc(kg: Double, impedances: [Double])     // 阻抗包（测量结束）
    }

    // MARK: - 位/字节工具
    private static func bit(_ v: Int, _ b: Int) -> Bool { (v & (1 << b)) != 0 }

    private static func u16(_ d: [UInt8], _ off: Int) -> Int {
        (Int(d[off]) << 8) | Int(d[off + 1])
    }
    private static func u32(_ d: [UInt8], _ off: Int) -> Int {
        (Int(d[off]) << 24) | (Int(d[off + 1]) << 16) | (Int(d[off + 2]) << 8) | Int(d[off + 3])
    }

    /// 对应 python 的 _get_int（带一点进位修正的取整）
    private static func getIntRound(_ value: Double) -> Int {
        (Int(value * 10.0) % 10) >= 9 ? Int(value + 1.0) : Int(value)
    }

    /// 对应 _gunit_general：按秤的刻度精度(division)把克数换算成公斤显示值
    private static func gunit(_ value: Double, _ division: Int) -> Double {
        switch division {
        case 0:
            let scaled = Int((Double(getIntRound(value * 1000.0)) + 5) / 10.0)
            return Double(scaled) / 100.0
        case 1:
            var raw = getIntRound(value * 1000.0)
            if raw % 10 == 9 { raw += 10 }
            var scaled = Int(Double(raw) / 10.0)
            if scaled % 2 != 0 { scaled += 1 }
            return Double(scaled) / 100.0
        case 2:
            let raw = Int((Double(getIntRound(value * 1000.0)) + 20) / 10.0)
            let scaled = (raw % 10 >= 5) ? ((raw / 10) * 10) + 5 : (raw / 10) * 10
            return Double(scaled) / 100.0
        case 3:
            let scaled = Int((Double(getIntRound(value * 100.0)) + 5) / 10.0)
            return Double(scaled) / 10.0
        case 4:
            var raw = getIntRound(value * 100.0)
            if raw % 10 == 9 { raw += 10 }
            var scaled = Int(Double(raw) / 10.0)
            if scaled % 2 != 0 { scaled += 1 }
            return Double(scaled) / 10.0
        default:
            return (value * 100).rounded() / 100
        }
    }

    /// 从 32 位编码里取出体重和"稳定"标志
    private static func weightFields(_ encoded: Int) -> (kg: Double, stable: Bool) {
        let grams = encoded & 0x3FFFF
        let kgDivision = (encoded & 0x1C0000) >> 18
        let kg = gunit(Double(grams) / 1000.0, kgDivision)
        return (kg, bit(encoded, 31))
    }

    /// 阻抗归一化（对应 normalize_impendences）
    private static func normalizeImpedances(_ adcs: [Double], _ weight: Double) -> [Double] {
        if adcs.count == 5 {
            return [adcs[4], adcs[0], adcs[1], adcs[2], adcs[3]].map { ($0 * 100).rounded() / 100 }
        }
        return adcs.map { v -> Double in
            var adj = v
            if adj >= 1500 && weight > 0 {
                adj = (((adj - 1000) + ((weight * 10) * -0.4)) / 0.6) / 10
            }
            return (adj * 100).rounded() / 100
        }
    }

    // MARK: - 下发用户资料（触发秤做体脂/阻抗测量）
    /// 对应 protocol.py 的 encode_time_and_user_info_27。
    /// 秤收到这一包（含年龄/身高/性别 + 启用阻抗的标志位）后，才会在称完体重后测体脂。
    /// - Parameter deviceType: 设备型号标识，直接取自收到的数据包第 2 个字节（如 0x29）。
    static func encodeUserInfo(deviceType: Int, profile: UserProfile) -> Data {
        var p = [UInt8]()
        p.append(0xAC)                                   // 0  包头
        p.append(UInt8(deviceType & 0xFF))               // 1  设备型号
        let now = UInt32(Date().timeIntervalSince1970)   // 2-5 当前时间(大端)
        p.append(UInt8((now >> 24) & 0xFF))
        p.append(UInt8((now >> 16) & 0xFF))
        p.append(UInt8((now >> 8) & 0xFF))
        p.append(UInt8(now & 0xFF))
        p.append(UInt8(truncatingIfNeeded: TimeZone.current.secondsFromGMT() / 900)) // 6 时区(15分钟为单位)
        p.append(0)                                      // 7  单位 0=kg
        p.append(1)                                      // 8  用户编号
        p.append(UInt8(Int(profile.heightCm) & 0xFF))    // 9  身高 cm
        p.append(0); p.append(0)                         // 10-11 档案体重(不填)
        p.append(UInt8(profile.age & 0xFF))              // 12 年龄
        p.append(profile.isMale ? 1 : 2)                 // 13 性别 1=男 2=女
        p.append(0); p.append(0)                         // 14-15 目标体重(不填)
        p.append(0x03)                                   // 16 功能位: bit0=启用阻抗/体脂测量
        p.append(0)                                      // 17
        p.append(0xD0)                                   // 18 包类型 208 = 设置时间+用户资料

        let checksum = p[2..<19].reduce(0) { $0 + Int($1) }
        p.append(UInt8(checksum & 0xFF))                 // 19 校验和
        return Data(p)
    }

    // MARK: - 解析入口
    static func isValidFrame(_ data: [UInt8]) -> Bool {
        guard data.count == 20, data[0] == 0xAC, !bit(Int(data[1]), 7) else { return false }
        // Incoming frames reserve the upper 3 checksum bits for group index.
        return data[2..<19].reduce(0) { $0 + Int($1) } & 0x1F == Int(data[19]) & 0x1F
    }

    static func decode(_ data: [UInt8]) -> Packet? {
        guard isValidFrame(data) else { return nil }
        let seqOrFlags = Int(data[1])
        if bit(seqOrFlags, 7) { return nil }      // 错误包

        let body18 = Array(data[2..<20])          // 18 字节
        let packetType = Int(body18[16])
        let groupIndex = (Int(body18[17]) & 0xE0) >> 5

        // payload = [device_type] + body18[0..<16] + [groupIndex]
        var payload: [UInt8] = [UInt8(seqOrFlags & 0xFF)]
        payload.append(contentsOf: body18[0..<16])
        payload.append(UInt8(groupIndex))

        switch packetType {
        case 213: return decodeWeight(payload)
        case 214: return decodeAdc(payload)
        case 216: return decodeHistory(payload)
        default:  return nil
        }
    }

    /// Single-frame history layouts from the upstream Scale27 protocol. Preserve
    /// the scale's Unix timestamp; malformed counts never consume trailer bytes.
    private static func decodeHistory(_ payload: [UInt8]) -> Packet? {
        let end = 17 // Exclude the group-index byte appended by decode.
        guard payload.count >= end else { return nil }
        var offset: Int
        let timestamp: Int
        let kg: Double
        var count: Int
        if payload[0] == 42 {
            timestamp = u32(payload, 1)
            kg = weightFields(u32(payload, 5)).kg
            offset = 9
            count = 1
        } else {
            timestamp = u32(payload, 2)
            kg = weightFields(u32(payload, 6)).kg
            switch payload[1] {
            case 0: count = Int(payload[13]); offset = 14
            case 2: count = Int(payload[11]); offset = 12
            case 1: count = 2; offset = 10
            default: return nil
            }
        }
        guard count > 0, offset + count * 2 <= end, kg > 2,
              timestamp >= 946684800 else { return nil }
        let date = Date(timeIntervalSince1970: Double(timestamp))
        guard date <= Date().addingTimeInterval(300) else { return nil }
        var impedances: [Double] = []
        for _ in 0..<count {
            impedances.append(Double(u16(payload, offset)))
            offset += 2
        }
        return .history(kg: kg, impedances: normalizeImpedances(impedances, kg), date: date)
    }

    private static func decodeWeight(_ payload: [UInt8]) -> Packet? {
        guard payload.count >= 6 else { return nil }
        let encoded = u32(payload, 1)             // payload[1..<5]
        let wf = weightFields(encoded)
        return .weight(kg: wf.kg, stable: wf.stable)
    }

    private static func decodeAdc(_ payload: [UInt8]) -> Packet? {
        guard payload.count >= 5, !bit(Int(payload[0]), 7) else { return nil }
        let count = Int(payload[1])
        var offset = 3
        var adcs: [Double] = []
        for _ in 0..<count {
            guard offset + 2 <= payload.count else { return nil }
            adcs.append(Double(u16(payload, offset)))
            offset += 2
        }
        guard offset < payload.count else { return nil }
        let mode = Int(payload[offset]); offset += 1

        var kg = 0.0
        if mode == 1, offset + 4 <= payload.count {
            kg = weightFields(u32(payload, offset)).kg
        }
        return .adc(kg: kg, impedances: normalizeImpedances(adcs, kg))
    }
}
