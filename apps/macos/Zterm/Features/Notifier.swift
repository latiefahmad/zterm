import AppKit
import UserNotifications

/// Notifikasi macOS untuk peringatan Dashboard (server mati, disk/RAM/CPU di atas 90%).
/// Klik notifikasi → buka Dashboard.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private weak var model: AppModel?

    func install(model: AppModel) {
        self.model = model
        UNUserNotificationCenter.current().delegate = self
    }

    /// Minta izin notifikasi; false bila ditolak (atur di System Settings → Notifications).
    func requestPermission() async -> Bool {
        let c = UNUserNotificationCenter.current()
        let settings = await c.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .denied: return false
        default: return (try? await c.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    /// `key` mengelompokkan notifikasi yang sama (notifikasi baru menggantikan yang lama).
    func send(title: String, body: String, key: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "dashboard"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            NSApp.activate()
            guard let model, model.phase == .main else { return }
            model.section = .dashboard
            model.showHome()
        }
    }
}
