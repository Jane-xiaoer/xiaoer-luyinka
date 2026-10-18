import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Dock 图标直接用包里的 AppIcon：系统图标缓存旧了（比如装过开发版）也不会显示成 Flutter 默认图标
  override func applicationWillFinishLaunching(_ notification: Notification) {
    if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
    super.applicationWillFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
