import AVFoundation
import Cocoa
import CoreAudio
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
    SysAudio.shared.register(flutterViewController.engine.binaryMessenger)
    FlutterMethodChannel(name: "luyinka/files", binaryMessenger: flutterViewController.engine.binaryMessenger)
      .setMethodCallHandler { call, result in
        guard call.method == "download", let path = call.arguments as? String else { return result(FlutterMethodNotImplemented) }
        // 资料文件夹里被挪到云上的文件：请 iCloud 在后台下载回来（不等它下完）
        DispatchQueue.global(qos: .utility).async {
          let fm = FileManager.default
          var n = 0
          if let e = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey]) {
            for case let url as URL in e {
              let st = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
              if st == .notDownloaded, (try? fm.startDownloadingUbiquitousItem(at: url)) != nil { n += 1 }
            }
          }
          DispatchQueue.main.async { result(n) }
        }
      }

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

// ───────── 录电脑声音（现场会议「也录电脑声音」）─────────
// 用 macOS 14.2 起的「录某个程序的声音」（Core Audio 进程录音，不用录屏）：
// 录电脑里除了本 App 以外的所有声音（腾讯会议 / 飞书 / Zoom… 对方说话都在里面）。
// 转成 16k 单声道 16 位，经 luyinka/sysaudio/pcm 一块一块送给 Dart，跟麦克风混在一起识别。
// 第一次用系统会问「录制系统音频」的权限。

final class SysAudio: NSObject, FlutterStreamHandler {
  static let shared = SysAudio()
  static let meetingApps = [
    ("com.tencent.meeting", "腾讯会议"), ("com.electron.lark", "飞书"), ("com.bytedance.lark", "飞书"),
    ("us.zoom", "Zoom"), ("com.tencent.xinWeChat", "微信"), ("com.microsoft.teams", "Teams"),
    ("com.apple.FaceTime", "FaceTime"), ("com.dingtalk", "钉钉"), ("com.alibaba.DingTalk", "钉钉"),
  ]

  private var sink: FlutterEventSink?
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?
  private var inFormat: AVAudioFormat?
  private let queue = DispatchQueue(label: "luyinka.sysaudio")

  func register(_ messenger: FlutterBinaryMessenger) {
    FlutterEventChannel(name: "luyinka/sysaudio/pcm", binaryMessenger: messenger).setStreamHandler(self)
    FlutterMethodChannel(name: "luyinka/sysaudio", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "supported":
        if #available(macOS 14.2, *) { result(true) } else { result(false) }
      case "start":
        if #available(macOS 14.2, *) {
          do { result(try self.start()) } catch { result(FlutterError(code: "start", message: "\(error)", details: nil)) }
        } else {
          result(FlutterError(code: "old", message: "要 macOS 14.2 以上才能录电脑声音", details: nil))
        }
      case "stop":
        self.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    let err = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
    return err == noErr ? value : nil
  }

  private func processes() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
  }

  private func bundleOf(_ p: AudioObjectID) -> String {
    (prop(p, kAudioProcessPropertyBundleID, "" as CFString) as String?) ?? ""
  }

  private func defaultOutputUID() throws -> String {
    guard let dev = prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(0)),
          let uid = prop(dev, kAudioDevicePropertyDeviceUID, "" as CFString) else {
      throw NSError(domain: "sysaudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到电脑的声音输出设备"])
    }
    return uid as String
  }

  /// 开录。返回录的是什么（「腾讯会议」/「电脑里的所有声音」），给界面显示。
  @available(macOS 14.2, *)
  func start() throws -> String {
    stop()
    // 不挑程序：录电脑里除了本 App 以外的所有声音。按程序挑会漏（微信开着就被当成会议程序；
    // 腾讯会议有时用别的子进程出声），2026-10-25 实测挑了微信、浏览器里的视频就没录上
    let me = processes().filter { bundleOf($0) == Bundle.main.bundleIdentifier }
    let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: me)
    let what = "电脑声音"
    desc.uuid = UUID()
    desc.muteBehavior = .unmuted
    desc.isPrivate = true
    var tap = AudioObjectID(kAudioObjectUnknown)
    var err = AudioHardwareCreateProcessTap(desc, &tap)
    guard err == noErr else {
      throw NSError(domain: "sysaudio", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "录不了电脑声音（\(err)）：系统设置 → 隐私与安全性 → 录屏与系统录音 里允许小耳录音卡"])
    }
    tapID = tap
    guard var asbd = prop(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription()),
          let fmt = AVAudioFormat(streamDescription: &asbd) else {
      stop()
      throw NSError(domain: "sysaudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "读不到电脑声音的格式"])
    }
    inFormat = fmt
    pos = 0
    let out = try defaultOutputUID()
    let agg: [String: Any] = [
      kAudioAggregateDeviceNameKey: "小耳录音卡·电脑声音",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: out,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: out]],
      kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
    ]
    var aggDev = AudioObjectID(kAudioObjectUnknown)
    err = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggDev)
    guard err == noErr else {
      stop()
      throw NSError(domain: "sysaudio", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "建不了录音通道（\(err)）"])
    }
    aggID = aggDev
    rate = prop(aggDev, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? fmt.sampleRate
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self = self else { return }
      self.rate = self.prop(aggDev, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? self.rate
    }
    rateListener = listener
    AudioObjectAddPropertyListenerBlock(aggDev, &rateAddr, queue, listener)
    err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggDev, queue) { [weak self] _, input, _, _, _ in
      self?.convert(input)
    }
    guard err == noErr else {
      stop()
      throw NSError(domain: "sysaudio", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "开不了录音（\(err)）"])
    }
    err = AudioDeviceStart(aggDev, procID)
    guard err == noErr else {
      stop()
      throw NSError(domain: "sysaudio", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "开不了录音（\(err)）"])
    }
    NSLog("[sys] started format=%@ rate=%.0f", fmt.description, rate)
    return what
  }

  private var pos: Double = 0 // 降采样走到哪了（跨段接着走）
  /// 送来的数据实际的采样率。不能信录音通道报的格式（总说 48k）：AirPods 被开会程序占着麦克风时
  /// 切到通话模式跑 24k，按 48k 算就成了 2 倍速、识别全乱（2026-10-25 实测）。按输出设备当下的算，变了跟着变。
  private var rate: Double = 48000
  private var rateListener: AudioObjectPropertyListenerBlock?
  private var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  /// 收到的一组缓冲：前面可能是输出设备自带的输入（比如 AirPods 的麦克风），电脑声音那一路排在最后
  private func convert(_ input: UnsafePointer<AudioBufferList>) {
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard inFormat != nil, let sink = sink, let tap = list.last, let raw = tap.mData, tap.mDataByteSize > 0 else { return }
    // 自己降：多声道平均成单声道，48k 每 3 个采样平均成 1 个（16k）。系统的变采样器一次只喂 10ms，
    // 段和段之间接不上，出来全是咔哒声，识别不出字（2026-10-25 实测）。
    let ch = max(1, Int(tap.mNumberChannels))
    let frames = Int(tap.mDataByteSize) / 4 / ch
    let src = raw.assumingMemoryBound(to: Float.self)
    let step = rate / 16000
    var out = [Int16]()
    out.reserveCapacity(Int(Double(frames) / step) + 1)
    while pos < Double(frames) {
      let start = Int(pos), end = min(frames, Int(pos + step))
      var sum: Float = 0
      for i in start..<max(start + 1, end) {
        for c in 0..<ch { sum += src[i * ch + c] }
      }
      let v = sum / Float(max(1, end - start) * ch)
      out.append(Int16(max(-1, min(1, v)) * 32767))
      pos += step
    }
    pos -= Double(frames) // 不整除时把余下的带到下一段，接缝处不丢不重
    let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
    DispatchQueue.main.async { sink(FlutterStandardTypedData(bytes: data)) }
  }

  func stop() {
    if aggID != kAudioObjectUnknown {
      if let l = rateListener { AudioObjectRemovePropertyListenerBlock(aggID, &rateAddr, queue, l) }
      AudioDeviceStop(aggID, procID)
      if let p = procID { AudioDeviceDestroyIOProcID(aggID, p) }
      AudioHardwareDestroyAggregateDevice(aggID)
    }
    if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
      AudioHardwareDestroyProcessTap(tapID)
    }
    procID = nil
    rateListener = nil
    aggID = AudioObjectID(kAudioObjectUnknown)
    tapID = AudioObjectID(kAudioObjectUnknown)
    inFormat = nil
  }
}
