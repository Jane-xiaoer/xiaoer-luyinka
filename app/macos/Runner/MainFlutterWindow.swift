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

  // 标题栏透明后整块都是 Flutter 画的：顶上 34pt 那条（App 里那里不放按钮）按住拖窗口、双击放大
  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown, let view = contentView,
       event.locationInWindow.y > view.frame.height - 34, event.locationInWindow.x > 80 {
      if event.clickCount == 2 { zoom(nil) } else { performDrag(with: event) }
      return
    }
    super.sendEvent(event)
  }
}
