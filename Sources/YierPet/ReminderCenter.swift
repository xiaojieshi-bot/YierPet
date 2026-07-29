import Foundation

enum ReminderKind: String, CaseIterable {
    case sedentary
    case water
    case lateNight
    case slacking
    // System sentinel
    case cpuHigh
    case memoryPressure
    case batteryLow
    case batteryFull
    case diskFull
    // Companion mode（陪伴模式）
    case morningGreet
    case lunchTime
    case afternoonCoffee
    case fridayEvening
    case ideOvertime

    var title: String {
        switch self {
        case .sedentary: return "久坐提醒"
        case .water: return "喝水提醒"
        case .lateNight: return "深夜关怀"
        case .slacking: return "摸鱼检测"
        case .cpuHigh: return "CPU 红温"
        case .memoryPressure: return "内存压力"
        case .batteryLow: return "电量提醒"
        case .batteryFull: return "充满提醒"
        case .diskFull: return "磁盘空间"
        case .morningGreet: return "早晨问候"
        case .lunchTime: return "午饭提醒"
        case .afternoonCoffee: return "下午咖啡"
        case .fridayEvening: return "周五撒欢"
        case .ideOvertime: return "编码久战"
        }
    }

    var isSystem: Bool {
        switch self {
        case .cpuHigh, .memoryPressure, .batteryLow, .batteryFull, .diskFull:
            return true
        default:
            return false
        }
    }

    /// 陪伴模式提醒（时间节律 + 编码久战）。
    var isCompanion: Bool {
        switch self {
        case .morningGreet, .lunchTime, .afternoonCoffee, .fridayEvening,
            .ideOvertime:
            return true
        default:
            return false
        }
    }

    static var healthCases: [ReminderKind] {
        allCases.filter { !$0.isSystem && !$0.isCompanion }
    }
    static var systemCases: [ReminderKind] { allCases.filter { $0.isSystem } }
    static var companionCases: [ReminderKind] {
        allCases.filter { $0.isCompanion }
    }

    var defaultsKey: String { "reminder.\(rawValue).enabled" }
}

protocol ReminderCenterDelegate: AnyObject {
    func reminderCenter(
        _ center: ReminderCenter, fire kind: ReminderKind, message: String)
    func reminderCenter(_ center: ReminderCenter, sleepyChanged sleepy: Bool)
    /// CPU heat level 0...1 for the red-hot visual effect.
    func reminderCenter(_ center: ReminderCenter, heatChanged level: Double)
}

/// Schedules health reminders and the system sentinel. Ticks every 30s,
/// checks conditions, applies priority + a global gap so bubbles never pile up.
final class ReminderCenter {
    weak var delegate: ReminderCenterDelegate?

    private let monitor = ActivityMonitor()
    private let systemMonitor = SystemMonitor()
    private var timer: Timer?

    // Tunables
    private let tick: TimeInterval = 30
    private let presenceIdleLimit: TimeInterval = 5 * 60   // away after 5 min idle
    private let sedentaryLimit: TimeInterval = 60 * 60     // 1h continuous activity
    private let waterInterval: TimeInterval = 30 * 60      // every 30 min
    private let slackLimit: TimeInterval = 30 * 60         // 30 min in slack app
    private let slackRepeat: TimeInterval = 15 * 60        // nag again every 15 min
    private let lateCareInterval: TimeInterval = 30 * 60   // late-night care every 30 min
    private let globalGap: TimeInterval = 90               // min gap between any two

    // System sentinel tunables
    private let cpuHighThreshold = 0.85     // sustained usage ratio
    private let cpuHighTicksNeeded = 3      // 3 ticks = 90s sustained
    private let cpuRepeat: TimeInterval = 10 * 60
    private let memRepeat: TimeInterval = 10 * 60
    private let diskFreeThreshold = 0.10    // alert below 10% free
    private let diskRepeat: TimeInterval = 6 * 3600

    // State
    private var activeSeconds: TimeInterval = 0
    private var waterSeconds: TimeInterval = 0
    private var lastSlackFire = Date.distantPast
    private var lastLateFire = Date.distantPast
    private var lastAnyFire = Date.distantPast
    private(set) var sleepy = false

    // System sentinel state
    private var cpuHighTicks = 0
    private var lastCpuFire = Date.distantPast
    private var lastMemFire = Date.distantPast
    private var lastDiskFire = Date.distantPast
    private var batteryStage = 0            // 0 none, 1 fired ≤20%, 2 fired ≤10%
    private var pendingBatteryStage = 0
    private var batteryFullFired = false
    /// Companion mode state
    private var firedToday: Set<ReminderKind> = []
    private var lastResetDay = Calendar.current.component(.day, from: Date())
    private var ideWorkSeconds: TimeInterval = 0
    private var fridayFiredWeek = 0    // 周五撒欢每周一次（weekOfYear）
    /// Live values substituted into "{v}" placeholders.
    private var pendingDetail: [ReminderKind: String] = [:]

    private static let messages: [ReminderKind: [String]] = [
        .sedentary: [
            "坐了一个小时啦，起来动动嘛！",
            "屁股要生根啦～站起来伸个懒腰吧！",
            "陪我走两步？你都坐一小时了！",
            "久坐伤腰！起来倒杯水顺便活动一下～",
        ],
        .water: [
            "咕噜咕噜～该喝水啦！",
            "你已经半小时没喝水了哦，抿一口嘛",
            "多喝水才有精神呀，去接杯水吧！",
            "我都替你渴了……喝口水好不好？",
        ],
        .lateNight: [
            "这么晚了还在忙呀，早点休息嘛……",
            "夜深了，工作再多也要爱惜自己哦",
            "我都困了 zzZ……你也快睡吧？",
            "熬夜会秃的！明天再做也来得及～",
            "夜深了，有我陪你呀，但也别熬太晚哦～",
            "再忙也有我在身边，加油之余记得休息～",
            "夜里静悄悄的，有我陪着你，忙完就去睡吧～",
        ],
        .slacking: [
            "都摸鱼半小时了哦……我可什么都没看见",
            "视频好看吗？要不要考虑干点活？",
            "嘘——老板来了！（骗你的，但也该收心啦）",
            "摸鱼一时爽，一直摸鱼一直慌哦～",
        ],
        .cpuHigh: [
            "好烫好烫！CPU 都 {v} 了，是谁在偷偷挖矿！",
            "呼——风扇都要起飞啦，CPU 飙到 {v}！",
            "红温警告！我要被烤熟了……快看看哪个 App 在发疯！",
            "炫……烫烫烫！CPU {v}，快救救我！",
        ],
        .memoryPressure: [
            "内存要被挤爆啦，关几个 App 让我喘口气～",
            "好挤呀……内存不够用了，清理一下嘛",
            "App 开太多啦，我都快被挤出屏幕了！",
        ],
        .batteryLow: [
            "电量只剩 {v} 啦，快给我充电！",
            "肚子饿了……电池只有 {v} 了，插电插电！",
            "再不充电我们就要一起睡着了哦（{v}）",
        ],
        .batteryFull: [
            "吃饱啦～电池充满了，可以拔线啦！",
            "满电出发！记得拔掉充电线哦～",
        ],
        .diskFull: [
            "磁盘只剩 {v} 空位啦，该大扫除了！",
            "装不下啦……磁盘剩 {v}，删点东西嘛",
        ],
        .morningGreet: [
            "早上好呀！今天也要元气满满哦～",
            "新的一天开始啦，冲鸭冲鸭！",
            "早安早安～今天想做点什么呀？",
            "太阳晒屁股啦，今天也请多指教！",
        ],
        .lunchTime: [
            "咕咕咕～到饭点啦，去吃点好的！",
            "十二点啦！干饭人干饭魂，走起走起～",
            "肚子是不是咕咕叫啦？该吃午饭咯！",
            "再忙也要好好吃饭呀，午饭时间到！",
        ],
        .afternoonCoffee: [
            "下午三点啦，来杯咖啡提提神？",
            "下午茶时间到～来点咖啡或小点心嘛！",
            "有点困了吧？喝口咖啡满血复活！",
        ],
        .fridayEvening: [
            "周五啦！晚上要不要犒劳一下自己～",
            "耶！周五晚上到咯，尽情撒欢吧！",
            "辛苦一周啦，今晚好好放松一下嘛～",
            "周末近在眼前，先嗨一个再说！",
        ],
        .ideOvertime: [
            "代码写两个小时啦，起来伸个懒腰嘛！",
            "敲了好久键盘啦，让眼睛休息一下下～",
            "连续奋战两小时！起来走走喝口水吧？",
            "卷了两个钟头啦……劳逸结合才高效哦！",
        ],
    ]

    /// Fallback values for "{v}" when fired from the test menu.
    private static let testDetails: [ReminderKind: String] = [
        .cpuHigh: "97%",
        .batteryLow: "18%",
        .diskFull: "9GB",
    ]

    /// Sticker tags implied by the frontmost app, for context-aware idling.
    var frontEmotionTags: [String] { monitor.frontCategory?.emotionTags ?? [] }

    func isEnabled(_ kind: ReminderKind) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: kind.defaultsKey) == nil { return true }
        return defaults.bool(forKey: kind.defaultsKey)
    }

    func setEnabled(_ kind: ReminderKind, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: kind.defaultsKey)
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: tick, repeats: true
        ) { [weak self] _ in
            self?.tickNow()
        }
        systemMonitor.startMemoryPressureWatch()
        _ = systemMonitor.cpuUsage()  // establish CPU baseline
        updateSleepy()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Fire a reminder immediately (also used by the test menu).
    func fire(_ kind: ReminderKind) {
        switch kind {
        case .sedentary: activeSeconds = 0
        case .water: waterSeconds = 0
        case .slacking: lastSlackFire = Date()
        case .lateNight: lastLateFire = Date()
        case .cpuHigh:
            lastCpuFire = Date()
            cpuHighTicks = 0
        case .memoryPressure: lastMemFire = Date()
        case .batteryLow: batteryStage = max(batteryStage, pendingBatteryStage)
        case .batteryFull: batteryFullFired = true
        case .diskFull: lastDiskFire = Date()
        case .morningGreet, .lunchTime, .afternoonCoffee:
            firedToday.insert(kind)
        case .fridayEvening:
            fridayFiredWeek = Calendar.current.component(
                .weekOfYear, from: Date())
        case .ideOvertime:
            ideWorkSeconds = 0
        }
        lastAnyFire = Date()
        var message = Self.messages[kind]?.randomElement() ?? ""
        let detail = pendingDetail[kind] ?? Self.testDetails[kind] ?? ""
        message = message.replacingOccurrences(of: "{v}", with: detail)
        delegate?.reminderCenter(self, fire: kind, message: message)
    }

    private func updateSleepy() {
        let hour = Calendar.current.component(.hour, from: Date())
        let night = hour >= 23 || hour < 5
        if night != sleepy {
            sleepy = night
            delegate?.reminderCenter(self, sleepyChanged: night)
        }
    }

    private func tickNow() {
        // 跨天清空「今日已触发」记录
        let today = Calendar.current.component(.day, from: Date())
        if today != lastResetDay {
            firedToday.removeAll()
            lastResetDay = today
        }

        let idle = ActivityMonitor.idleSeconds()
        let present = idle < presenceIdleLimit

        if present {
            activeSeconds += tick
            waterSeconds += tick
        } else {
            // User walked away: sitting streak is broken.
            activeSeconds = 0
        }

        // IDE / 终端连续编码时长：人在且前台是编码类才累加；
        // 离开即断；前台切到其他 App 时仅不累加、不清零。
        if present,
            monitor.frontCategory == .ide || monitor.frontCategory == .terminal {
            ideWorkSeconds += tick
        }
        if !present { ideWorkSeconds = 0 }

        updateSleepy()

        // --- System sentinel sampling (every tick, independent of gap) ---
        let sysCandidates = sampleSystem()

        guard Date().timeIntervalSince(lastAnyFire) >= globalGap else { return }

        // System anomalies first, then health reminders:
        // sedentary > lateNight > water > slacking
        var candidates: [ReminderKind] = sysCandidates
        if isEnabled(.sedentary), activeSeconds >= sedentaryLimit {
            candidates.append(.sedentary)
        }
        if isEnabled(.lateNight), sleepy, present,
            Date().timeIntervalSince(lastLateFire) >= lateCareInterval {
            candidates.append(.lateNight)
        }
        if isEnabled(.water), waterSeconds >= waterInterval {
            candidates.append(.water)
        }
        if isEnabled(.slacking), monitor.slackingSeconds >= slackLimit,
            Date().timeIntervalSince(lastSlackFire) >= slackRepeat {
            candidates.append(.slacking)
        }

        // 陪伴模式：时间节律候选，优先级低于所有健康提醒
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let weekday = Calendar.current.component(.weekday, from: now)
        let weekOfYear = Calendar.current.component(.weekOfYear, from: now)
        if isEnabled(.morningGreet), present, (6...10).contains(hour),
            !firedToday.contains(.morningGreet) {
            candidates.append(.morningGreet)
        }
        if isEnabled(.lunchTime), present, hour == 12,
            !firedToday.contains(.lunchTime) {
            candidates.append(.lunchTime)
        }
        if isEnabled(.afternoonCoffee), present, hour == 15,
            !firedToday.contains(.afternoonCoffee) {
            candidates.append(.afternoonCoffee)
        }
        if isEnabled(.fridayEvening), present, weekday == 6,
            (17...19).contains(hour), fridayFiredWeek != weekOfYear {
            candidates.append(.fridayEvening)
        }
        if isEnabled(.ideOvertime), ideWorkSeconds >= 2 * 3600 {
            candidates.append(.ideOvertime)
        }

        if let kind = candidates.first {
            fire(kind)
        }
    }

    /// Samples system metrics, updates the heat visual, and returns
    /// anomaly candidates in priority order: cpu > memory > battery > disk.
    private func sampleSystem() -> [ReminderKind] {
        var candidates: [ReminderKind] = []

        // CPU + red-hot visual
        let cpu = systemMonitor.cpuUsage()
        let heat = min(max((cpu - 0.6) / 0.4, 0), 1)
        delegate?.reminderCenter(
            self, heatChanged: isEnabled(.cpuHigh) ? heat : 0)
        if cpu >= cpuHighThreshold {
            cpuHighTicks += 1
        } else {
            cpuHighTicks = 0
        }
        if isEnabled(.cpuHigh), cpuHighTicks >= cpuHighTicksNeeded,
            Date().timeIntervalSince(lastCpuFire) >= cpuRepeat {
            pendingDetail[.cpuHigh] = "\(Int(cpu * 100))%"
            candidates.append(.cpuHigh)
        }

        // Memory pressure (event-driven flag, critical only)
        if isEnabled(.memoryPressure), systemMonitor.memoryPressureCritical,
            Date().timeIntervalSince(lastMemFire) >= memRepeat {
            candidates.append(.memoryPressure)
        }

        // Battery (skipped on desktops without a battery)
        if let battery = systemMonitor.batteryState() {
            if battery.onACPower {
                batteryStage = 0
                if isEnabled(.batteryFull), battery.percent >= 98,
                    !batteryFullFired {
                    candidates.append(.batteryFull)
                }
            } else {
                batteryFullFired = false
                if battery.percent > 25 { batteryStage = 0 }
                pendingBatteryStage =
                    battery.percent <= 10 ? 2 : battery.percent <= 20 ? 1 : 0
                if isEnabled(.batteryLow), pendingBatteryStage > batteryStage {
                    pendingDetail[.batteryLow] = "\(battery.percent)%"
                    candidates.append(.batteryLow)
                }
            }
        }

        // Disk space
        if isEnabled(.diskFull), let disk = systemMonitor.diskFree(),
            disk.ratio < diskFreeThreshold,
            Date().timeIntervalSince(lastDiskFire) >= diskRepeat {
            pendingDetail[.diskFull] = String(format: "%.0fGB", disk.freeGB)
            candidates.append(.diskFull)
        }

        return candidates
    }
}
