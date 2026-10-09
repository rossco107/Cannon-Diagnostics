
//  Canon Diagnostics
//
//  Copyright © 2026 Ross Carter. All rights reserved.
//
//  Native macOS application for reading Canon EOS camera
//  information using USB/PTP without external dependencies.
//

import SwiftUI
import AppKit

@main
struct CanonUSBApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}
