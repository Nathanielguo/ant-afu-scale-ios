import SwiftUI
import Charts

private enum WellnessTheme {
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let ink = Color(uiColor: .label)
    static let secondaryInk = Color(uiColor: .secondaryLabel)
    static let accent = Color(red: 0.08, green: 0.48, blue: 0.40)
    static let accentDeep = Color(red: 0.03, green: 0.25, blue: 0.22)
    static let accentMint = Color(red: 0.78, green: 0.93, blue: 0.87)
    static let warm = Color(red: 0.96, green: 0.62, blue: 0.30)
    static let danger = Color(red: 0.83, green: 0.20, blue: 0.22)
    static let gradient = LinearGradient(
        colors: [accentDeep, accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let canvasGradient = LinearGradient(
        colors: [accentMint.opacity(0.34), canvas],
        startPoint: .topLeading,
        endPoint: .center
    )
}

struct ContentView: View {
    @StateObject private var ble = BluetoothManager()
    @StateObject private var health = HealthKitManager()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var weightFontSize = 64

    @State private var profile = UserProfile.load()
    @State private var activeSheet: SheetDestination?
    @State private var records = ConfirmedMeasurements.load()

    private enum SheetDestination: String, Identifiable {
        case profile

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WellnessTheme.canvasGradient
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        statusBanner
                        if let message = health.message {
                            healthSyncBanner(message: message)
                        }
                        if let pending = ble.pendingMeasurement {
                            ownershipCard(pending)
                        }
                        primaryMeasurement

                        if let measurement = ble.lastMeasurement {
                            metricsSection(measurement)
                        } else {
                            gettingStartedCard
                        }

                        if !records.isEmpty {
                            confirmedHistoryCard
                        }

                        measurementTip
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: 0).background(.ultraThinMaterial)
            }
            .safeAreaInset(edge: .bottom) {
                actionButton
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $activeSheet) { destination in
                switch destination {
                case .profile:
                    ProfileView(profile: $profile)
                }
            }
            .task {
                ble.onMeasurementReady = { _ in
                    records = ConfirmedMeasurements.load()
                    Task { await health.syncPending() }
                }
                ble.setForeground(scenePhase == .active)
                await health.syncPending()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active || phase == .background {
                    ble.setForeground(phase == .active)
                }
                if phase == .active { Task { await health.syncPending() } }
            }
            .onChange(of: profile) { _ in
                ble.settingsChanged()
                Task { await health.syncPending() }
            }
        }
        .tint(WellnessTheme.accent)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(Date(), style: .date)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(WellnessTheme.secondaryInk)

                Text("身体记录")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(WellnessTheme.ink)

                if !dynamicTypeSize.isAccessibilitySize {
                    Text(profile.autoConnect ? "靠近并唤醒秤，数据自动同步" : "记录每一次变化，了解自己的节奏")
                        .font(.subheadline)
                        .foregroundStyle(WellnessTheme.secondaryInk)
                }
            }

            Spacer(minLength: 12)

            Button {
                activeSheet = .profile
                fireHaptic()
            } label: {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(WellnessTheme.accent)
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 1))
            }
            .accessibilityLabel("打开我的资料")
        }
    }

    private var statusBanner: some View {
        let status = StatusPresentation(state: ble.state, monitoring: ble.isMonitoring, autoConnect: profile.autoConnect)

        return HStack(spacing: 13) {
            Image(systemName: status.icon)
                .font(.headline.weight(.semibold))
                .foregroundStyle(status.tint)
                .frame(width: 38, height: 38)
                .background(status.tint.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WellnessTheme.ink)
                Text(status.subtitle)
                    .font(.caption)
                    .foregroundStyle(WellnessTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                if ble.state == .measuring, let weight = ble.liveWeight {
                    Text(String(format: "实时体重 %.2f kg", weight))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
            }

            Spacer(minLength: 8)

            if status.isBusy {
                ProgressView()
                    .tint(status.tint)
                    .scaleEffect(0.85)
            } else if status.isPositive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(status.tint)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.42), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Primary measurement

    @ViewBuilder
    private var primaryMeasurement: some View {
        if ble.state == .measuring, let weight = ble.liveWeight {
            liveMeasurementCard(weight)
        } else if let measurement = ble.lastMeasurement {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(Calendar.current.isDateInToday(measurement.date) ? "今日最近测量" : "最近一次测量", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))

                    Spacer()

                    if !dynamicTypeSize.isAccessibilitySize {
                        Text("本机已保存")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("体重")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(String(format: "%.2f", measurement.weightKg))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .font(.system(size: weightFontSize, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.65)
                            .lineLimit(1)
                        Text("kg")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                }

                if let previous = records.first(where: { $0.id != measurement.id && $0.date < measurement.date }) {
                    let change = measurement.weightKg - previous.weightKg
                    Label(String(format: "较上次 %+.2f kg", change), systemImage: abs(change) < 0.01 ? "equal" : (change > 0 ? "arrow.up.right" : "arrow.down.right"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.86))
                }
                let columns = dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : Array(repeating: GridItem(.flexible()), count: 2)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    heroStat(title: "BMI", value: String(format: "%.1f", measurement.bmi))
                    heroStat(title: "体脂率 · 估算", value: String(format: "%.1f%%", measurement.bodyFatPercent))
                }

                Text(measurement.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WellnessTheme.gradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 138, height: 138)
                    .blur(radius: 1)
                    .offset(x: 40, y: -45)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: WellnessTheme.accentDeep.opacity(0.16), radius: 16, y: 8)
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: "figure.stand")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(.white.opacity(0.16), in: Circle())

                    Spacer()

                    Image(systemName: "sparkles")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.78))
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("建立你的第一条记录")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                    Text(profile.autoConnect ? "打开蓝牙并唤醒体脂秤，光脚上秤即可。首次读数会请你确认本人。" : "先填写身体资料，再点击下方连接体脂秤。首次读数会请你确认本人。")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.74))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                    Text("本地计算 · 私密记录")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WellnessTheme.gradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: WellnessTheme.accentDeep.opacity(0.22), radius: 22, y: 12)
        }
    }

    private func liveMeasurementCard(_ weight: Double) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("正在读取本次体重", systemImage: "waveform.path.ecg")
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.2f", weight))
                    .font(.system(size: weightFontSize, weight: .bold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                Text("kg").font(.title3.weight(.semibold))
            }
            Text("保持站立，等待读数稳定和体脂测量完成。")
                .font(.subheadline)
            Text("完成后判断测量归属，再保存和同步。")
                .font(.caption).foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WellnessTheme.gradient, in: RoundedRectangle(cornerRadius: 28))
        .accessibilityElement(children: .combine)
    }

    private func heroStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Metrics and guidance

    private func metricsSection(_ measurement: Measurement) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "更多身体指标", subtitle: "对应最近已保存记录")

            LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                MetricTile(icon: "drop.fill", label: "水分率", value: String(format: "%.1f%%", measurement.waterPercent), tint: Color.blue)
                MetricTile(icon: "figure.strengthtraining.traditional", label: "肌肉率", value: String(format: "%.1f%%", measurement.muscleRate), tint: Color.indigo)
                MetricTile(icon: "flame.fill", label: "基础代谢", value: "\(measurement.bmr) kcal", tint: Color.orange)
                MetricTile(icon: "scalemass.fill", label: "去脂体重", value: String(format: "%.1f kg", measurement.leanBodyMassKg), tint: WellnessTheme.accent)
            }
        }
    }

    private var gettingStartedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "测量前准备", subtitle: "约 1 分钟完成")

            VStack(alignment: .leading, spacing: 13) {
                preparationRow(icon: "person.text.rectangle.fill", text: "先在右上角填写身高、年龄和性别")
                preparationRow(icon: "antenna.radiowaves.left.and.right", text: "打开蓝牙，让体脂秤保持在手机附近")
                preparationRow(icon: "figure.stand", text: "光脚站上金属电极，保持身体稳定")
            }
            .padding(17)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var measurementTip: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(WellnessTheme.warm)
                .frame(width: 30, height: 30)
                .background(WellnessTheme.warm.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("让记录更有参考价值")
                    .font(.subheadline.weight(.semibold))
                Text("尽量在相近的时间、相近的状态下测量。体脂数据适合观察趋势，不替代医疗判断。")
                    .font(.caption)
                    .foregroundStyle(WellnessTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .background(WellnessTheme.card.opacity(0.78), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(WellnessTheme.warm.opacity(0.18), lineWidth: 1)
        )
    }

    private func preparationRow(icon: String, text: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WellnessTheme.accent)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(WellnessTheme.ink)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .lastTextBaseline))
        return layout {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(WellnessTheme.ink)
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(WellnessTheme.secondaryInk)
        }
    }

    private func healthSyncBanner(message: String) -> some View {
        let succeeded = message.contains("已同步")
        let tint = health.isSyncing || succeeded ? WellnessTheme.accent : WellnessTheme.warm
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if health.isSyncing { ProgressView().tint(tint) }
                else { Image(systemName: succeeded ? "heart.fill" : "exclamationmark.circle.fill").foregroundStyle(tint) }
                Text(health.isSyncing ? "正在同步健康" : (succeeded ? "Apple 健康已更新" : "健康同步待处理"))
                    .font(.subheadline.weight(.semibold))
            }
            if !succeeded {
                Text(message).font(.caption).foregroundStyle(WellnessTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if health.pendingCount > 0 && !health.isSyncing {
                Button {
                    if profile.autoSyncHealth { Task { await health.syncPending() } }
                    else { activeSheet = .profile }
                } label: {
                    Label(profile.autoSyncHealth ? "重试同步（\(health.pendingCount) 条）" : "前往设置开启同步", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }

    private var confirmedHistoryCard: some View {
        let recent = Array(records.prefix(10))
        let chronological = recent.reversed()
        let weights = recent.map(\.weightKg)
        return VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "体重趋势", subtitle: "最近 \(recent.count) 次")
            if recent.count > 1, let low = weights.min(), let high = weights.max() {
                Chart(Array(chronological)) { measurement in
                    LineMark(x: .value("日期", measurement.date), y: .value("体重 kg", measurement.weightKg))
                        .foregroundStyle(WellnessTheme.accent)
                    PointMark(x: .value("日期", measurement.date), y: .value("体重 kg", measurement.weightKg))
                        .foregroundStyle(WellnessTheme.accent).symbolSize(24)
                }
                .chartYScale(domain: (low - 1)...(high + 1))
                .chartYAxis { AxisMarks(position: .leading) }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                .frame(height: 150)
                Text("单位 kg · 仅包含已确认属于本人的记录")
                    .font(.caption).foregroundStyle(WellnessTheme.secondaryInk)
            } else {
                Text("已有第一条记录。再测一次，就能看到体重变化。")
                    .font(.subheadline).foregroundStyle(WellnessTheme.secondaryInk)
            }
            DisclosureGroup("查看最近记录") {
                VStack(spacing: 12) {
                    ForEach(recent) { measurement in
                        HStack(alignment: .firstTextBaseline) {
                            Text(measurement.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(WellnessTheme.secondaryInk)
                            Spacer(minLength: 8)
                            Text(String(format: "%.2f kg", measurement.weightKg))
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }.padding(.top, 12)
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(17)
        .background(WellnessTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func ownershipCard(_ measurement: Measurement) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("这次测量是你本人吗？", systemImage: "person.crop.circle.badge.questionmark")
                .font(.headline)
            Text(String(format: "%.2f kg", measurement.weightKg))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text(measurement.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
            Text(ble.confirmationReason ?? "请确认测量归属")
                .font(.subheadline)
            Text("确认后保存并按设置同步健康。体重接近不能证明身份，共用秤时可开启每次确认。")
                .font(.caption).foregroundStyle(WellnessTheme.secondaryInk)

        }
        .padding(17)
        .background(WellnessTheme.warm.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Action

    @ViewBuilder
    private var actionButton: some View {
        if let pending = ble.pendingMeasurement {
            VStack(spacing: 8) {
                Text(String(format: "确认是否本人：%.2f kg", pending.weightKg))
                    .font(.caption).foregroundStyle(WellnessTheme.secondaryInk)
                let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    Button("不是我，忽略") { fireHaptic(); ble.resolvePending(accept: false) }
                        .buttonStyle(.bordered)
                        .tint(WellnessTheme.ink)
                    Button("是我，保存") { fireHaptic(); ble.resolvePending(accept: true) }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
        } else if ble.isMonitoring {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(WellnessTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.autoConnect ? "自动连接已开启" : "正在连接体脂秤")
                        .font(.subheadline.weight(.semibold))
                    Text("保持 App 打开，靠近并唤醒秤")
                        .font(.caption).foregroundStyle(WellnessTheme.secondaryInk)
                }
                Spacer(minLength: 4)
                Button("暂停") { fireHaptic(); ble.cancel() }
                    .buttonStyle(.bordered).frame(minHeight: 44)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHint("暂停连接，下次打开 App 时按设置恢复")
            }
            .padding(.vertical, 6)
        } else {
            Button {
                fireHaptic()
                ble.startMeasurement()
            } label: {
                Label("连接体脂秤", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(WellnessTheme.gradient, in: RoundedRectangle(cornerRadius: 17))
            }
            .buttonStyle(.plain)
            .accessibilityHint("扫描并连接体脂秤")
        }
    }

    private func fireHaptic() {
        #if !os(macOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }
}

private struct MetricTile: View {
    let icon: String
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(WellnessTheme.ink)
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(WellnessTheme.secondaryInk)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .padding(15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.36), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)，\(value)")
    }
}

private struct StatusPresentation {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    let isBusy: Bool
    let isPositive: Bool

    init(state: ScaleState, monitoring: Bool, autoConnect: Bool) {
        switch state {
        case .idle:
            icon = "figure.stand"
            title = autoConnect ? "连接已暂停" : "手动连接模式"
            subtitle = autoConnect ? "点击下方连接，或下次打开 App 自动恢复" : "点击下方连接体脂秤开始测量"
            tint = WellnessTheme.accent
            isBusy = false
            isPositive = false
        case .poweredOff:
            icon = "antenna.radiowaves.left.and.right.slash"
            title = "蓝牙未开启"
            subtitle = "请在系统设置中打开蓝牙后重试"
            tint = WellnessTheme.warm
            isBusy = false
            isPositive = false
        case .scanning:
            icon = "antenna.radiowaves.left.and.right"
            title = "正在寻找体脂秤"
            subtitle = "请让体脂秤保持唤醒并靠近手机"
            tint = WellnessTheme.accent
            isBusy = true
            isPositive = false
        case .connecting:
            icon = "link"
            title = "正在连接"
            subtitle = "马上就好，连接成功后请站上秤"
            tint = WellnessTheme.accent
            isBusy = true
            isPositive = false
        case .measuring:
            icon = "waveform.path.ecg"
            title = "已连接，等待读数"
            subtitle = "光脚上秤，稳定后自动读取；异常体重会等待确认"
            tint = WellnessTheme.accent
            isBusy = true
            isPositive = false
        case .awaitingConfirmation:
            icon = "person.crop.circle.badge.questionmark"
            title = "等待确认测量归属"
            subtitle = "确认前不会覆盖本人记录或写入健康"
            tint = WellnessTheme.warm
            isBusy = false
            isPositive = false
        case .done:
            icon = "checkmark.circle.fill"
            title = "测量完成"
            subtitle = "结果已计算并保存在本机"
            tint = WellnessTheme.accent
            isBusy = false
            isPositive = true
        case .bodyFatUnavailable(let hint):
            icon = "exclamationmark.triangle.fill"
            title = "体脂测量未完成"
            subtitle = hint
            tint = WellnessTheme.warm
            isBusy = false
            isPositive = false
        case .error(let message):
            icon = "xmark.circle.fill"
            title = "连接状态"
            subtitle = message
            tint = monitoring ? WellnessTheme.warm : WellnessTheme.danger
            isBusy = false
            isPositive = false
        }
    }
}

// MARK: - Profile

struct ProfileView: View {
    @Binding private var profile: UserProfile
    @State private var draft: UserProfile
    @Environment(\.dismiss) private var dismiss

    init(profile: Binding<UserProfile>) {
        _profile = profile
        _draft = State(initialValue: profile.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WellnessTheme.canvasGradient
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        profileIntro
                        bodyDataCard
                        automationCard
                        healthSyncCard
                        profileNote
                    }
                    .padding(20)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("资料与同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        profile = draft
                        draft.save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(WellnessTheme.accent)
    }

    private var profileIntro: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 32))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(WellnessTheme.accent)
                .frame(width: 62, height: 62)
                .background(WellnessTheme.accentMint, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("让估算更贴近你")
                    .font(.headline.weight(.bold))
                Text("这些资料只保存在本机，用于计算身体组成。")
                    .font(.caption)
                    .foregroundStyle(WellnessTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var bodyDataCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("身体资料")
                .font(.headline.weight(.bold))

            profileStepperRow(
                icon: "ruler.fill",
                title: "身高",
                value: "\(Int(draft.heightCm)) cm",
                tint: WellnessTheme.accent,
                binding: $draft.heightCm,
                range: 80...230
            )

            Divider().padding(.leading, 43)

            profileStepperRow(
                icon: "calendar",
                title: "年龄",
                value: "\(draft.age) 岁",
                tint: Color.indigo,
                binding: $draft.age,
                range: 5...120
            )

            Divider().padding(.leading, 43)

            VStack(alignment: .leading, spacing: 10) {
                Label("生理性别", systemImage: "person.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(WellnessTheme.secondaryInk)

                HStack(spacing: 8) {
                    genderButton(title: "男", isSelected: draft.isMale) {
                        draft.isMale = true
                    }
                    genderButton(title: "女", isSelected: !draft.isMale) {
                        draft.isMale = false
                    }
                }
            }
        }
        .padding(17)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var automationCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("连接与测量归属").font(.headline.weight(.bold))
            Toggle("打开 App 自动连接", isOn: $draft.autoConnect)
            Text("在前台寻找已记住的秤，断线后自动重连。秤需唤醒并在蓝牙范围内。")
                .font(.caption).foregroundStyle(WellnessTheme.secondaryInk)
            Divider()
            Toggle("每次都确认是本人", isOn: $draft.confirmEveryMeasurement)
            if !draft.confirmEveryMeasurement {
                Stepper(value: $draft.weightToleranceKg, in: 0.5...10, step: 0.5) {
                    Text(String(format: "允许体重偏差：±%.1f kg", draft.weightToleranceKg))
                }
            }
            Text(draft.confirmEveryMeasurement ? "每条记录都由你确认后保存，适合家人共用一台秤。" : "首次、超过允许偏差或 30 天未更新时需要确认。体重相近的家人可能被误判，共用秤建议开启每次确认。")
                .font(.caption).foregroundStyle(WellnessTheme.secondaryInk)
        }
        .padding(17)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var healthSyncCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "heart.text.square.fill")
                .font(.title3)
                .foregroundStyle(WellnessTheme.accent)
                .frame(width: 36, height: 36)
                .background(WellnessTheme.accentMint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Toggle("同步到 Apple 健康", isOn: $draft.autoSyncHealth)
                    .font(.subheadline.weight(.semibold))
                Text("确认本人后写入体重、体脂率、BMI 和去脂体重。失败保留待同步记录，打开 App 或点击重试可补写；关闭后暂停补写。")
                    .font(.caption)
                    .foregroundStyle(WellnessTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(17)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var profileNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(WellnessTheme.secondaryInk)
            Text("体脂、水分和肌肉等数据由体脂秤原始阻值经本地公式估算，仅适合观察趋势，不用于医疗诊断。")
                .font(.caption)
                .foregroundStyle(WellnessTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 3)
    }

    private func profileStepperRow<T: Strideable & CVarArg>(
        icon: String,
        title: String,
        value: String,
        tint: Color,
        binding: Binding<T>,
        range: ClosedRange<T>
    ) -> some View where T.Stride: SignedNumeric {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(WellnessTheme.secondaryInk)
                Text(value)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(WellnessTheme.ink)
            }

            Spacer()

            Stepper("调整\(title)", value: binding, in: range)
                .labelsHidden()
                .accessibilityValue(value)
        }
    }

    private func genderButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .white : WellnessTheme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(isSelected ? WellnessTheme.accent : WellnessTheme.canvas.opacity(0.70), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ProfileView_Previews: PreviewProvider {
    static var previews: some View {
        ProfileView(profile: .constant(UserProfile()))
    }
}
