//
//  AppDelegate.swift
//  CinePlanner
//
//  The two things project sharing needs from the app delegate: an invitation
//  link the user opened (accepted here, so the project joins the shared store),
//  and pushes from iCloud (so a shared project fetches right away instead of
//  waiting for the sync engine's schedule).
//

import SwiftUI
import CloudKit

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { await ProjectSync.shared.accept(metadata) }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return }
        ProjectSync.shared.receivedPush(scope: (notification as? CKDatabaseNotification)?.databaseScope)
    }
}
#else
final class AppDelegate: NSObject, UIApplicationDelegate {
    // On iOS an accepted share reaches the scene, so the scene gets a delegate too.
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return .noData }
        ProjectSync.shared.receivedPush(scope: (notification as? CKDatabaseNotification)?.databaseScope)
        return .newData
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    // Launched by opening an invitation…
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Task { await ProjectSync.shared.accept(metadata) }
        }
    }

    // …or opening one while running.
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { await ProjectSync.shared.accept(metadata) }
    }
}
#endif
