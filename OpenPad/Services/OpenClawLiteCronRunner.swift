import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

@MainActor
final class OpenClawLiteCronRunner: ObservableObject {
    static let shared = OpenClawLiteCronRunner()

    @Published private(set) var lastRunSummary: String = ""

    private var timer: Timer?

    func start() {
        stop()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func runNow(cron: LocalCron) {
        execute(cron: cron, source: "manual")
    }

    func validate(schedule: String) -> (ok: Bool, message: String) {
        let parts = schedule.split(separator: " ").map(String.init)
        guard parts.count >= 2 else {
            return (false, "Formato inválido. Usa al menos: minuto hora (ej: 0 9 * * *)")
        }
        let m = validateField(parts[0], range: 0...59, label: "minuto")
        if !m.ok { return m }
        let h = validateField(parts[1], range: 0...23, label: "hora")
        if !h.ok { return h }
        return (true, "Cron válido")
    }

    private func validateField(_ field: String, range: ClosedRange<Int>, label: String) -> (ok: Bool, message: String) {
        if field == "*" { return (true, "") }
        guard let n = Int(field), range.contains(n) else {
            return (false, "Valor inválido en \(label): \(field)")
        }
        return (true, "")
    }

    private func tick() {
        let rows = OpenClawLiteAutomationStore.shared.loadCrons().filter { $0.enabled }
        guard !rows.isEmpty else { return }

        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let stamp = stampKey(date: now)

        var fired: [String] = []

        for cron in rows {
            if matches(schedule: cron.schedule, hour: hour, minute: minute) {
                let key = "\(cron.id.uuidString)-\(stamp)"
                if UserDefaults.standard.bool(forKey: key) { continue }
                UserDefaults.standard.set(true, forKey: key)
                fired.append(cron.title)
                execute(cron: cron, source: "timer")
            }
        }

        if !fired.isEmpty {
            lastRunSummary = "Ejecutados: " + fired.joined(separator: ", ")
        }
    }

    private func execute(cron: LocalCron, source: String) {
        notify(title: "Cron ejecutado", body: "\(cron.title): \(cron.command)")
        let log = LocalCronLog(
            cronId: cron.id,
            title: cron.title,
            command: cron.command,
            executedAt: Date(),
            source: source,
            success: true,
            note: "OK"
        )
        OpenClawLiteAutomationStore.shared.appendCronLog(log)
        lastRunSummary = "\(cron.title) (\(source))"
    }

    private func matches(schedule: String, hour: Int, minute: Int) -> Bool {
        let parts = schedule.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return false }

        func matchField(_ field: String, value: Int) -> Bool {
            if field == "*" { return true }
            if let n = Int(field) { return n == value }
            return false
        }

        return matchField(parts[0], value: minute) && matchField(parts[1], value: hour)
    }

    private func stampKey(date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmm"
        return f.string(from: date)
    }

    private func notify(title: String, body: String) {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req)
        #else
        _ = title
        _ = body
        #endif
    }
}
