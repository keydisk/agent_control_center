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

    super.awakeFromNib()
  }
}
