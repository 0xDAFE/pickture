//
//  PicktureApp.swift
//  Pickture
//
//  Created by Vibe Coder on 27.09.26.
//

import SwiftUI

@main
struct PicktureApp: App {
    @State private var session = CullingSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        Task {
                            await session.flushPendingWrites()
                        }
                    }
                }
                #if os(macOS)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    Task {
                        await session.flushPendingWrites()
                    }
                }
                #endif
        }
        #if os(macOS)
        Settings {
            SettingsSheetView(session: session, showsDismissButton: false)
        }
        #endif
    }
}
