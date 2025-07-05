//
//  TestApp.swift
//  Test
//
//  Created by 1 on 23/06/25.
//

import SwiftUI

@main
struct TestApp: App {
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // App is going to background - backup drafts to UserDefaults
                print("📱 App going to background - backing up drafts...")
                BlogStore.shared.backupDraftMetadata()
            case .inactive:
                // App is becoming inactive - also backup drafts
                print("📱 App becoming inactive - backing up drafts...")
                BlogStore.shared.backupDraftMetadata()
            case .active:
                print("📱 App became active")
            @unknown default:
                break
            }
        }
    }
}
