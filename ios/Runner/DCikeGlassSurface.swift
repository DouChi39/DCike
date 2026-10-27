import Flutter
import UIKit

/// Native Liquid Glass surface used by detail/settings cards.
/// iOS 26 and newer use Apple's UIGlassEffect. Older supported systems use
/// the native material blur so the same layout still has a platform surface.
final class DCikeGlassSurfaceFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    DCikeGlassSurfacePlatformView(frame: frame, args: args)
  }
}

private final class DCikeGlassSurfacePlatformView: NSObject, FlutterPlatformView {
  private let surface: DCikeGlassSurface

  init(frame: CGRect, args: Any?) {
    surface = DCikeGlassSurface(frame: frame)
    super.init()
    surface.configure(args as? [String: Any] ?? [:])
  }

  func view() -> UIView { surface }
}

private final class DCikeGlassSurface: UIView {
  // Start without an effect; refreshEffect installs UIGlassEffect on iOS 26
  // and the native material fallback on earlier iOS versions.
  private let material = UIVisualEffectView(effect: nil)
  private var darkMode = false
  private var styleName = "regular"
  private var configuredRadius: CGFloat = 20

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    isUserInteractionEnabled = false
    material.isUserInteractionEnabled = false
    material.clipsToBounds = true
    addSubview(material)
    refreshEffect()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(_ values: [String: Any]) {
    darkMode = values["darkMode"] as? Bool ?? false
    styleName = values["style"] as? String ?? "regular"
    if let radius = (values["cornerRadius"] as? NSNumber)?.doubleValue {
      configuredRadius = max(0, CGFloat(radius))
    }
    overrideUserInterfaceStyle = darkMode ? .dark : .light
    refreshEffect()
    setNeedsLayout()
  }

  private func refreshEffect() {
    if UIAccessibility.isReduceTransparencyEnabled {
      material.effect = nil
      material.backgroundColor = darkMode
        ? UIColor.secondarySystemBackground.withAlphaComponent(0.92)
        : UIColor.systemBackground.withAlphaComponent(0.92)
    } else if #available(iOS 26.0, *) {
      let glass: UIGlassEffect
      if styleName == "clear" {
        glass = UIGlassEffect(style: .clear)
      } else {
        glass = UIGlassEffect(style: .regular)
      }
      glass.isInteractive = true
      material.effect = glass
      material.backgroundColor = .clear
    } else {
      material.effect = UIBlurEffect(
        style: darkMode ? .systemChromeMaterialDark : .systemChromeMaterialLight
      )
      material.backgroundColor = .clear
    }
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = darkMode ? 0.28 : 0.12
    layer.shadowRadius = 16
    layer.shadowOffset = CGSize(width: 0, height: 5)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
          bounds.width.isFinite, bounds.height.isFinite,
          bounds.width >= 0, bounds.height >= 0 else { return }
    material.frame = bounds
    material.layer.cornerRadius = configuredRadius
    material.layer.cornerCurve = .continuous
    layer.shadowPath = UIBezierPath(
      roundedRect: bounds,
      cornerRadius: configuredRadius
    ).cgPath
  }
}
