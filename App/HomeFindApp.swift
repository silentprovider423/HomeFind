import SwiftUI
import BackgroundTasks
import UserNotifications

@main
struct HomeFindApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in Task { await model.handleURL(url) } }
        }
        .onChange(of: phase, initial: true) { _, p in
            switch p {
            case .active: model.sceneBecameActive()
            case .background: model.sceneEnteredBackground()
            default: break
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await AppModel.shared.backgroundRefresh()
        }
    }
}

extension AppModel {
    /// Eine Instanz für App, Hintergrund-Abruf und Mitteilungs-Aktionen.
    static let shared = AppModel()
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Bei Start durch einen Ortswechsel (App war beendet) sofort wieder überwachen.
        _ = AppModel.shared
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let pid = info["personId"] as? Int
        let rid = info["requestId"] as? Int
        await MainActor.run {
            var dict: [AnyHashable: Any] = [:]
            if let pid { dict["personId"] = pid }
            if let rid { dict["requestId"] = rid }
            Task { await AppModel.shared.handleNotificationAction(action, userInfo: dict) }
        }
    }
}

enum BackgroundRefresh {
    static let identifier = "org.homeroll.homefind.refresh"

    /// Nächsten Abruf anmelden (iOS entscheidet den Zeitpunkt, frühestens nach 15 Min.).
    static func schedule(endOfDay: Date?) {
        let req = BGAppRefreshTaskRequest(identifier: identifier)
        var earliest = Date.now.addingTimeInterval(15 * 60)
        if let endOfDay, endOfDay > .now, endOfDay < earliest { earliest = endOfDay }
        req.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(req)
    }
}
