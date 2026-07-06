import Foundation
import UIKit
import UserNotifications

@MainActor
final class PushNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushNotificationManager()

    private var lastRegisteredToken: String?

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func registerForRemoteNotifications() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else { return }
        case .authorized, .provisional, .ephemeral:
            break
        default:
            return
        }

        UIApplication.shared.registerForRemoteNotifications()
    }

    func handleDeviceToken(_ deviceToken: Data) async {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard token != lastRegisteredToken else { return }

        do {
            try await CopareAPI.shared.registerDevice(token: token)
            lastRegisteredToken = token
        } catch {
            print("[push] failed to register device token:", error.localizedDescription)
        }
    }

    func handleRegistrationFailure(_ error: Error) {
        print("[push] APNs registration failed:", error.localizedDescription)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { await PushNotificationManager.shared.handleDeviceToken(deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushNotificationManager.shared.handleRegistrationFailure(error)
        }
    }
}
