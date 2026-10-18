import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // 默认 1280×820 居中；标题栏透明，App 自己的顶栏就是标题栏（红绿灯压在左上）
    self.setContentSize(NSSize(width: 1280, height: 820))
    self.minSize = NSSize(width: 900, height: 600)
    self.center()
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)
    self.setFrameAutosaveName("LuyinkaMain")

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
