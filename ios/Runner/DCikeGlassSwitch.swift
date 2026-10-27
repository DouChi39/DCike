import Flutter
import UIKit

/// Native iOS switch used by settings rows. On iOS 26 the surrounding
/// surface is backed by UIGlassEffect; UISwitch remains Apple's native control.
final class DCikeGlassSwitchFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64,
              arguments args: Any?) -> FlutterPlatformView {
    DCikeGlassSwitchPlatformView(frame: frame, id: viewId,
                                 args: args, messenger: messenger)
  }
}

private final class DCikeGlassSwitchPlatformView: NSObject, FlutterPlatformView {
  private let control: DCikeGlassSwitch
  private let channel: FlutterMethodChannel

  init(frame: CGRect, id: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
    control = DCikeGlassSwitch(frame: frame)
    channel = FlutterMethodChannel(name: "dcike/native_glass_switch/\(id)",
                                   binaryMessenger: messenger)
    super.init()
    control.onChanged = { [weak self] value in
      self?.channel.invokeMethod("valueChanged", arguments: value)
    }
    control.configure(args as? [String: Any] ?? [:])
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      guard call.method == "update" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.control.configure(call.arguments as? [String: Any] ?? [:])
      result(nil)
    }
  }

  func view() -> UIView { control }

  deinit { channel.setMethodCallHandler(nil) }
}

private final class DCikeGlassSwitch: UIView {
  var onChanged: ((Bool) -> Void)?
  private let toggle = UISwitch()
  private var darkMode = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = true
    // UISwitch already owns its native track and thumb. A second material
    // layer here creates a translucent white disk around every switch.
    addSubview(toggle)
    toggle.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
    toggle.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      toggle.leadingAnchor.constraint(equalTo: leadingAnchor),
      toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
      toggle.topAnchor.constraint(equalTo: topAnchor),
      toggle.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    refreshGlass()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(_ values: [String: Any]) {
    let value = values["value"] as? Bool ?? false
    let enabled = values["enabled"] as? Bool ?? true
    darkMode = values["darkMode"] as? Bool ?? false
    toggle.setOn(value, animated: false)
    toggle.isEnabled = enabled
    overrideUserInterfaceStyle = darkMode ? .dark : .light
    refreshGlass()
  }

  @objc private func valueChanged() { onChanged?(toggle.isOn) }

  private func refreshGlass() {
    toggle.backgroundColor = .clear
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0
    layer.shadowRadius = 0
    layer.shadowOffset = .zero
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.width.isFinite, bounds.height.isFinite,
          bounds.width > 0, bounds.height > 0 else { return }
  }
}
