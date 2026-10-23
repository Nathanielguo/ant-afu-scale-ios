import Foundation
import Combine
import CoreBluetooth

enum ScaleState: Equatable {
    case idle, poweredOff, scanning, connecting, measuring, done, awaitingConfirmation
    case bodyFatUnavailable(String)
    case error(String)
}

/// Foreground-only connection loop. Delegate callbacks use the main queue.
@MainActor
final class BluetoothManager: NSObject, ObservableObject {
    private let serviceUUID = CBUUID(string: "FFB0")
    @Published var state: ScaleState = .idle
    @Published var liveWeight: Double?
    @Published var lastMeasurement: Measurement? = .loadLatest()
    @Published private(set) var pendingMeasurement: Measurement? = loadPending()
    @Published private(set) var confirmationReason: String?
    @Published private(set) var isMonitoring = false

    var onMeasurementReady: ((Measurement) -> Void)?
    private var profile: UserProfile = .load()
    private var central: CBCentralManager!
    private var scale: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var locked = false
    private var didSendProfile = false
    private var lastWeightAt: Date?
    private var hasStableWeight = false
    private var lastReceived: Measurement?
    private var timeoutTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryDelay: UInt64 = 5
    private var isForeground = false
    private var manuallyPaused = false
    private var manualSession = false
    private var useKnownPeripheral = true

    private var lastPeripheralID: UUID? {
        get { UserDefaults.standard.string(forKey: "last_peripheral").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "last_peripheral") }
    }

    private static func loadPending() -> Measurement? {
        guard let data = UserDefaults.standard.data(forKey: "unconfirmed_measurement") else { return nil }
        return try? JSONDecoder().decode(Measurement.self, from: data)
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func setForeground(_ active: Bool) {
        let wasForeground = isForeground
        isForeground = active
        if active {
            if !wasForeground { manuallyPaused = false }
            profile = .load()
            if pendingMeasurement != nil {
                confirmationReason = "有一条尚未确认的测量，请确认归属后继续。"
                state = .awaitingConfirmation
            }
            resumeIfNeeded()
        } else {
            stopConnection()
        }
    }

    func settingsChanged() {
        profile = .load()
        if !profile.autoConnect && !manualSession { stopConnection() }
        resumeIfNeeded()
    }

    func startMeasurement() {
        manuallyPaused = false
        manualSession = true
        profile = .load()
        resumeIfNeeded()
    }

    func cancel() {
        manuallyPaused = true
        manualSession = false
        stopConnection()
        state = .idle
    }

    private func resumeIfNeeded() {
        guard isForeground, !manuallyPaused, profile.autoConnect || manualSession,
              pendingMeasurement == nil, scale == nil, retryTask == nil, !central.isScanning else { return }
        switch central.state {
        case .poweredOn: beginConnection()
        case .unauthorized: state = .error("蓝牙权限未授予，请在系统设置中允许访问")
        case .unsupported: state = .error("此设备不支持蓝牙连接")
        case .poweredOff: state = .poweredOff
        default: break // Wait for centralManagerDidUpdateState before connecting.
        }
    }

    private func beginConnection() {
        isMonitoring = true
        resetReading()
        if useKnownPeripheral, let id = lastPeripheralID,
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        } else {
            state = .scanning
            central.scanForPeripherals(withServices: [serviceUUID], options: nil)
        }
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self else { return }
            self.connectionFailed("暂未找到已唤醒的体脂秤，稍后自动重试")
        }
    }

    private func resetReading() {
        locked = false
        didSendProfile = false
        liveWeight = nil
        lastWeightAt = nil
        hasStableWeight = false
    }

    private func stopConnection() {
        timeoutTask?.cancel()
        timeoutTask = nil
        retryTask?.cancel()
        retryTask = nil
        central.stopScan()
        let oldScale = scale
        scale = nil // Ignore late callbacks from cancelled sessions.
        writeChar = nil
        isMonitoring = false
        if let oldScale { central.cancelPeripheralConnection(oldScale) }
    }

    private func connectionFailed(_ message: String) {
        stopConnection()
        state = .error(message)
        useKnownPeripheral = false // Next attempt scans for the remembered device.
        guard isForeground, !manuallyPaused, profile.autoConnect || manualSession,
              pendingMeasurement == nil, central.state == .poweredOn else { return }
        let delay = retryDelay
        retryDelay = min(30, retryDelay * 2)
        isMonitoring = true
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.resumeIfNeeded()
        }
    }

    private func connect(_ peripheral: CBPeripheral) {
        guard scale == nil else { return }
        central.stopScan()
        scale = peripheral
        peripheral.delegate = self
        state = .connecting
        central.connect(peripheral, options: nil)
    }

    private func sendUserProfile(deviceType: Int) {
        guard !didSendProfile, let scale, let writeChar else { return }
        let type: CBCharacteristicWriteType = writeChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        if type == .withoutResponse && !scale.canSendWriteWithoutResponse { return }
        scale.writeValue(Scale27.encodeUserInfo(deviceType: deviceType, profile: profile), for: writeChar, type: type)
        didSendProfile = true
    }

    private func handle(_ data: Data) {
        let bytes = [UInt8](data)
        guard pendingMeasurement == nil, Scale27.isValidFrame(bytes) else { return }
        sendUserProfile(deviceType: Int(data[1]))
        guard let packet = Scale27.decode(bytes) else { return }
        switch packet {
        case .weight(let kg, let stable):
            // An unloaded scale starts the next measurement without reconnecting.
            if kg <= 2 {
                locked = false
                liveWeight = nil
                hasStableWeight = false
                lastWeightAt = nil
                return
            }
            if locked, !stable, let lastReceived,
               Date().timeIntervalSince(lastReceived.date) >= 5 {
                locked = false
                hasStableWeight = false
            }
            guard kg.isFinite, !locked else { return }
            liveWeight = (kg * 100).rounded() / 100
            lastWeightAt = Date()
            hasStableWeight = stable
            state = .measuring
        case .adc(let kg, let impedances):
            // The supported protocol has no record ID or original timestamp. Only
            // accept ADC associated with a fresh, stable live reading.
            guard !locked, hasStableWeight, let liveWeight, let lastWeightAt,
                  Date().timeIntervalSince(lastWeightAt) < 60 else { return }
            let weight = kg > 2 ? kg : liveWeight
            guard weight.isFinite, abs(weight - liveWeight) <= 0.3 else { return }
            locked = true
            guard let impedance = impedances.first(where: { $0 >= 100 && $0 <= 1500 }) else {
                state = .bodyFatUnavailable("请光脚踩住电极，擦干脚底后重新上秤")
                return
            }
            let measurement = BodyComposition.calculate(weightKg: weight, impedance: impedance, profile: profile)
            guard !MeasurementOwnership.isRepeated(measurement, previous: lastReceived ?? lastMeasurement) else {
                state = .done
                return
            }
            process(measurement)
        case .history(let kg, let impedances, let date):
            guard let scale,
                  let impedance = impedances.first(where: { $0 >= 100 && $0 <= 1500 }) else { return }
            let id = ScaleHistoryIdentity.id(peripheral: scale.identifier, date: date, weight: kg, impedance: impedance)
            guard !ScaleHistoryIdentity.contains(id) else { return }
            let measurement = BodyComposition.calculate(weightKg: kg, impedance: impedance, profile: profile,
                                                        id: id, date: date)
            if MeasurementOwnership.isRepeated(measurement, previous: lastReceived ?? lastMeasurement) {
                ScaleHistoryIdentity.remember(id)
                return
            }
            process(measurement)

        }
    }

    private func process(_ measurement: Measurement) {
        lastReceived = measurement
        let reason = Date().timeIntervalSince(measurement.date) > 30 * 86400
            ? "这条秤端历史记录超过 30 天，请确认是否属于本人。"
            : MeasurementOwnership.confirmationReason(weight: measurement.weightKg, baseline: lastMeasurement, profile: profile)
        if let reason {
            pendingMeasurement = measurement
            confirmationReason = reason
            if let data = try? JSONEncoder().encode(measurement) {
                UserDefaults.standard.set(data, forKey: "unconfirmed_measurement")
            }
            stopConnection()
            state = .awaitingConfirmation
        } else {
            accept(measurement)
        }
    }

    func resolvePending(accept shouldAccept: Bool) {
        guard let measurement = pendingMeasurement else { return }
        lastReceived = measurement
        if shouldAccept { accept(measurement) }
        else { ScaleHistoryIdentity.remember(measurement.id); state = .idle }
        pendingMeasurement = nil
        confirmationReason = nil
        UserDefaults.standard.removeObject(forKey: "unconfirmed_measurement")
        manualSession = false
        resumeIfNeeded()
    }

    private func accept(_ measurement: Measurement) {
        ConfirmedMeasurements.save(measurement)
        // An older history record may be synced, but cannot roll back the baseline.
        if lastMeasurement == nil || measurement.date >= lastMeasurement!.date {
            lastMeasurement = measurement
            measurement.saveAsLatest()
        }
        if UserProfile.load().autoSyncHealth { HealthSyncQueue.enqueue(measurement) }
        ScaleHistoryIdentity.remember(measurement.id)
        state = .done
        onMeasurementReady?(measurement)
        if !profile.autoConnect {
            manualSession = false
            stopConnection()
        }
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state != .poweredOn { stopConnection() }
            resumeIfNeeded()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard isMonitoring, state == .scanning,
                  lastPeripheralID == nil || lastPeripheralID == peripheral.identifier else { return }
            connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard scale === peripheral else { return }
            peripheral.discoverServices([serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard scale === peripheral else { return }
            connectionFailed("连接失败，稍后自动重试")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard scale === peripheral else { return }
            connectionFailed("秤已断开，唤醒后将自动重连")
        }
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard scale === peripheral else { return }
            guard error == nil, let services = peripheral.services, !services.isEmpty else {
                connectionFailed("未发现体脂秤服务，将自动重试")
                return
            }
            for service in services { peripheral.discoverCharacteristics(nil, for: service) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard scale === peripheral else { return }
            guard error == nil, let characteristics = service.characteristics,
                  characteristics.contains(where: { $0.properties.contains(.notify) }),
                  let writable = characteristics.first(where: { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }) else {
                connectionFailed("秤的读写特征不可用，将自动重试")
                return
            }
            writeChar = writable
            for characteristic in characteristics where characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard scale === peripheral else { return }
            guard error == nil, characteristic.isNotifying else {
                connectionFailed("订阅读数失败，将自动重试")
                return
            }
            timeoutTask?.cancel()
            timeoutTask = nil
            lastPeripheralID = peripheral.identifier
            useKnownPeripheral = true
            retryDelay = 5
            state = .measuring
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard scale === peripheral, error != nil else { return }
            connectionFailed("下发身体资料失败，将自动重试")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard scale === peripheral else { return }
            guard error == nil, let data = characteristic.value else {
                connectionFailed("读取秤数据失败，将自动重试")
                return
            }
            handle(data)
        }
    }
}
