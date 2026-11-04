import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    flutterViewController.backgroundColor = .clear

    // Flutter 뷰 뒤에 사이드바 재질을 깔아 투명 영역이 창 뒤로 비치게 합니다.
    let material = NSVisualEffectView()
    material.material = .sidebar
    material.blendingMode = .behindWindow
    material.state = .followsWindowActiveState
    let containerViewController = NSViewController()
    containerViewController.view = material
    containerViewController.addChild(flutterViewController)
    flutterViewController.view.frame = material.bounds
    flutterViewController.view.autoresizingMask = [.width, .height]
    material.addSubview(flutterViewController.view)

    self.contentViewController = containerViewController
    self.styleMask.insert(.fullSizeContentView)
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.isOpaque = false
    self.backgroundColor = .clear
    self.setContentSize(NSSize(width: 1200, height: 780))
    self.contentMinSize = NSSize(width: 860, height: 560)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    let windowChannel = FlutterMethodChannel(
      name: "agent_control_center/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    windowChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "startDragging":
        if let event = self.currentEvent { self.performDrag(with: event) }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let pasteboardChannel = FlutterMethodChannel(
      name: "agent_control_center/pasteboard",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    pasteboardChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "readMediaPaths":
        result(MainFlutterWindow.pastedMediaPaths())
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  /// 클립보드의 파일 경로를 돌려줍니다. 이미지 데이터만 있으면 임시 PNG로 저장합니다.
  private static func pastedMediaPaths() -> [String] {
    let pasteboard = NSPasteboard.general
    let fileURLs = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL] ?? []
    if !fileURLs.isEmpty { return fileURLs.map(\.path) }

    // 표 복사처럼 텍스트를 우선하는 내용은 이미지로 가로채지 않습니다.
    let candidates: [NSPasteboard.PasteboardType] = [.png, .tiff, .string]
    guard
      let preferred = pasteboard.types?.first(where: candidates.contains),
      preferred != .string,
      let data = pasteboard.data(forType: preferred),
      // PNG를 다시 인코딩하면 잘못된 gAMA가 기록되어 색이 바래므로 그대로 저장합니다.
      let png = preferred == .png
        ? data
        : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    else { return [] }

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pasted-\(UUID().uuidString).png")
    guard (try? png.write(to: url)) != nil else { return [] }
    return [url.path]
  }
}
