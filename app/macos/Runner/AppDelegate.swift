import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Dock 图标直接用包里的 AppIcon：系统图标缓存旧了（比如装过开发版）也不会显示成 Flutter 默认图标
  override func applicationWillFinishLaunching(_ notification: Notification) {
    if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
    // 「文稿」开了 iCloud「优化 Mac 存储空间」时，文件会被挪到云上只留空壳。默认读它要等下载完，
    // iCloud 卡住（比如硬盘快满了）就一直等、窗口一片黑（2026-10-25 实测）。改成读不到直接报错，App 跳过、照常打开；
    // 再请系统在后台下载回来（luyinka/files download），下回来以后 App 每分钟重读一次。
    _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    super.applicationWillFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
