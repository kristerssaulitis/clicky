//
//  HomeSpaceWindowManager.swift
//  leanring-buddy
//
//  Owns the Home Space dashboard: a standard, resizable, activating NSWindow
//  (unlike the menu bar panel and cursor overlay, this window takes focus).
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let clickyOpenHomeSpace = Notification.Name("clickyOpenHomeSpace")
}

@MainActor
final class HomeSpaceWindowManager {

    private let companionManager: CompanionManager
    private var homeSpaceWindow: NSWindow?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager

        NotificationCenter.default.addObserver(
            forName: .clickyOpenHomeSpace,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showHomeSpace()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Opens (or focuses) the dashboard window.
    func showHomeSpace() {
        let window: NSWindow
        if let existingWindow = homeSpaceWindow {
            window = existingWindow
        } else {
            window = createHomeSpaceWindow()
            homeSpaceWindow = window
        }

        // A standard activating window — the dashboard should take focus so
        // the text input works immediately.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createHomeSpaceWindow() -> NSWindow {
        let homeSpaceView = HomeSpaceView(companionManager: companionManager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Home Space"
        window.minSize = NSSize(width: 560, height: 400)
        window.contentView = NSHostingView(rootView: homeSpaceView)
        window.center()
        window.isReleasedWhenClosed = false
        return window
    }
}
