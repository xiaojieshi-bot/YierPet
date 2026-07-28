import Foundation

enum ReminderKind: String, CaseIterable {
    case sedentary
    case water
    case lateNight
    case slacking

    var title: String {
        switch self {
        case .sedentary: return "久坐提醒"
        case .water: return "喝水提醒"
        case .lateNight: return "深夜关怀"
        case .slacking: return "摸鱼检测"
        }
    }

    var defaultsKey: String { "reminder.\(rawValue).enabled" }
}

protocol ReminderCenterDelegate: AnyObject {
    func reminderCenter(
        _ center: ReminderCenter, fire kind: ReminderKind, message: String)
    func reminderCenter(_ center: ReminderCenter, sleepyChanged sleepy: Bool)
}

/// Schedules the four health reminders. Ticks every 30s, checks conditions,
/// applies priority + a global gap so bubbles never pile up.
final class ReminderCenter {
    weak var delegate: ReminderCenterDelegate?

    private let monitor = ActivityMonitor()
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

    // State
    private var activeSeconds: TimeInterval = 0
    private var waterSeconds: TimeInterval = 0
    private var lastSlackFire = Date.distantPast
    private var lastLateFire = Date.distantPast
    private var lastAnyFire = Date.distantPast
    private(set) var sleepy = false

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
        ],
        .slacking: [
            "都摸鱼半小时了哦……我可什么都没看见",
            "视频好看吗？要不要考虑干点活？",
            "嘘——老板来了！（骗你的，但也该收心啦）",
            "摸鱼一时爽，一直摸鱼一直慌哦～",
        ],
    ]

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
        }
        lastAnyFire = Date()
        let message = Self.messages[kind]?.randomElement() ?? ""
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
        let idle = ActivityMonitor.idleSeconds()
        let present = idle < presenceIdleLimit

        if present {
            activeSeconds += tick
            waterSeconds += tick
        } else {
            // User walked away: sitting streak is broken.
            activeSeconds = 0
        }

        updateSleepy()

        guard Date().timeIntervalSince(lastAnyFire) >= globalGap else { return }

        // Candidates in priority order: sedentary > lateNight > water > slacking
        var candidates: [ReminderKind] = []
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

        if let kind = candidates.first {
            fire(kind)
        }
    }
}
