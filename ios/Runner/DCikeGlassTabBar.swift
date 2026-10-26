import Flutter
import UIKit

/// Only the navigation surface is native. Flutter retains each tab's navigator.
final class DCikeGlassTabBarFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
  ) -> FlutterPlatformView {
    DCikeGlassPlatformView(frame: frame, id: viewId, args: args, messenger: messenger)
  }
}

private final class DCikeGlassPlatformView: NSObject, FlutterPlatformView {
  private let tabBar: DCikeGlassTabBar
  private let channel: FlutterMethodChannel

  init(frame: CGRect, id: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
    tabBar = DCikeGlassTabBar(frame: frame)
    channel = FlutterMethodChannel(name: "dcike/native_tab_bar/\(id)", binaryMessenger: messenger)
    super.init()
    tabBar.configure(args as? [String: Any] ?? [:])
    tabBar.onSelected = { [weak self] index in
      self?.channel.invokeMethod("selectTab", arguments: index)
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      guard call.method == "update" else { result(FlutterMethodNotImplemented); return }
      self.tabBar.configure(call.arguments as? [String: Any] ?? [:])
      result(nil)
    }
  }

  func view() -> UIView { tabBar }

  deinit { channel.setMethodCallHandler(nil) }
}

private final class DCikeGlassTabBar: UIView {
  var onSelected: ((Int) -> Void)?
  private let material = UIVisualEffectView()
  private let lens = UIVisualEffectView()
  private let symbols = ["house", "cloud", "books.vertical", "safari", "square.grid.2x2"]
  private let filledSymbols = [
    "house.fill", "cloud.fill", "books.vertical.fill", "safari.fill", "square.grid.2x2.fill",
  ]
  private var buttons: [DCikeTabButton] = []
  private var selectedIndex = 0
  private var previewIndex = 0
  private var dragging = false
  private var dragX: CGFloat?
  private var isRtl = false
  private var darkMode = false
  private var materialDarkMode: Bool?
  private let feedback = UISelectionFeedbackGenerator()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    material.isUserInteractionEnabled = true
    material.clipsToBounds = true
    lens.isUserInteractionEnabled = false
    lens.clipsToBounds = true
    addSubview(material)
    material.contentView.addSubview(lens)
    for index in symbols.indices {
      let button = DCikeTabButton(type: .custom)
      button.tag = index
      button.addTarget(self, action: #selector(activate(_:)), for: .touchUpInside)
      material.contentView.addSubview(button)
      buttons.append(button)
    }
    let gesture = UILongPressGestureRecognizer(target: self, action: #selector(trackSelection(_:)))
    gesture.minimumPressDuration = 0
    gesture.allowableMovement = .greatestFiniteMagnitude
    material.addGestureRecognizer(gesture)
    NotificationCenter.default.addObserver(
      self, selector: #selector(accessibilityChanged),
      name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil
    )
    refreshMaterial()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit { NotificationCenter.default.removeObserver(self) }

  func configure(_ values: [String: Any]) {
    darkMode = values["darkMode"] as? Bool ?? false
    overrideUserInterfaceStyle = darkMode ? .dark : .light
    isRtl = values["isRtl"] as? Bool ?? false
    let labels = values["labels"] as? [String] ?? []
    let scale = min(1.5, max(1, (values["textScale"] as? NSNumber)?.doubleValue ?? 1))
    for (index, button) in buttons.enumerated() {
      let label = index < labels.count ? labels[index] : ""
      button.setTitle(label, for: .normal)
      button.accessibilityLabel = label
      button.titleLabel?.font = .systemFont(ofSize: 10 * CGFloat(scale), weight: .medium)
    }
    selectedIndex = min(buttons.count - 1, max(0, values["selectedIndex"] as? Int ?? 0))
    if !dragging { previewIndex = selectedIndex }
    if materialDarkMode != darkMode { refreshMaterial() }
    updateButtons()
    setNeedsLayout()
  }

  @objc private func accessibilityChanged() { refreshMaterial() }

  private func refreshMaterial() {
    materialDarkMode = darkMode
    // Actual Apple Liquid Glass on iOS 26; earlier systems get native material blur.
    if UIAccessibility.isReduceTransparencyEnabled {
      material.effect = nil
      lens.effect = nil
      material.backgroundColor = .secondarySystemBackground
      lens.backgroundColor = .tertiarySystemFill
    } else {
      material.backgroundColor = .clear
      lens.backgroundColor = .clear
      if #available(iOS 26.0, *) {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        material.effect = glass
        let selectionGlass = UIGlassEffect(style: .clear)
        selectionGlass.isInteractive = true
        selectionGlass.tintColor = UIColor.systemGray.withAlphaComponent(darkMode ? 0.24 : 0.12)
        lens.effect = selectionGlass
      } else {
        material.effect = UIBlurEffect(style: .systemMaterial)
        lens.effect = UIBlurEffect(style: .systemThickMaterial)
      }
    }
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = darkMode ? 0.3 : 0.13
    layer.shadowRadius = 10
    layer.shadowOffset = CGSize(width: 0, height: 3)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Insets keep the system material's rounded edge and shadow within Flutter's view.
    let width = min(520, max(0, bounds.width - 32))
    material.frame = CGRect(x: (bounds.width - width) / 2, y: 8, width: width, height: max(0, bounds.height - 16))
    material.layer.cornerRadius = material.bounds.height / 2
    material.layer.cornerCurve = .continuous
    layer.shadowPath = UIBezierPath(roundedRect: material.frame, cornerRadius: material.layer.cornerRadius).cgPath
    let itemWidth = max(0, (material.bounds.width - 8) / CGFloat(buttons.count))
    for (index, button) in buttons.enumerated() {
      let visualIndex = isRtl ? buttons.count - 1 - index : index
      button.frame = CGRect(x: 4 + CGFloat(visualIndex) * itemWidth, y: 4, width: itemWidth, height: max(0, material.bounds.height - 8))
    }
    positionLens(centerX: dragX)
  }

  private func positionLens(centerX: CGFloat? = nil) {
    guard buttons.indices.contains(previewIndex) else { return }
    var rect = buttons[previewIndex].frame
    if let centerX = centerX {
      rect.origin.x = min(material.bounds.width - 4 - rect.width, max(4, centerX - rect.width / 2))
    }
    lens.frame = rect
    lens.layer.cornerRadius = rect.height / 2
    lens.layer.cornerCurve = .continuous
  }

  private func index(at x: CGFloat) -> Int {
    let width = max(1, (material.bounds.width - 8) / CGFloat(buttons.count))
    let slot = min(buttons.count - 1, max(0, Int(floor((x - 4) / width))))
    return isRtl ? buttons.count - 1 - slot : slot
  }

  @objc private func trackSelection(_ gesture: UILongPressGestureRecognizer) {
    let point = gesture.location(in: material)
    switch gesture.state {
    case .began:
      lens.layer.removeAllAnimations()
      dragging = true
      feedback.prepare()
      fallthrough
    case .changed:
      let next = index(at: point.x)
      if next != previewIndex { feedback.selectionChanged(); feedback.prepare() }
      previewIndex = next
      dragX = point.x
      positionLens(centerX: point.x)
      updateButtons()
    case .ended:
      // Dragging far away cancels, just like moving outside a normal control.
      let isInside = material.bounds.insetBy(dx: -24, dy: -32).contains(point)
      finishSelection(isInside ? index(at: point.x) : selectedIndex, commit: isInside)
    case .cancelled, .failed:
      finishSelection(selectedIndex, commit: false)
    default:
      break
    }
  }

  @objc private func activate(_ sender: UIButton) { finishSelection(sender.tag, commit: true) }

  private func finishSelection(_ index: Int, commit: Bool) {
    dragging = false
    dragX = nil
    previewIndex = index
    if commit { selectedIndex = index }
    updateButtons()
    let changes = { self.positionLens() }
    if UIAccessibility.isReduceMotionEnabled {
      changes()
    } else {
      UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.78,
                     initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction],
                     animations: changes)
    }
    if commit { onSelected?(index) }
  }

  private func updateButtons() {
    for (index, button) in buttons.enumerated() {
      let active = index == previewIndex
      let color: UIColor = active ? .systemBlue : .secondaryLabel
      button.setImage(UIImage(systemName: active ? filledSymbols[index] : symbols[index],
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 23, weight: .medium)), for: .normal)
      button.tintColor = color
      button.setTitleColor(color, for: .normal)
      button.accessibilityTraits = index == selectedIndex ? [.button, .selected] : [.button]
    }
  }
}

private final class DCikeTabButton: UIButton {
  override func layoutSubviews() {
    super.layoutSubviews()
    imageView?.frame = CGRect(x: (bounds.width - 26) / 2, y: 6, width: 26, height: 26)
    imageView?.contentMode = .scaleAspectFit
    titleLabel?.frame = CGRect(x: 2, y: 34, width: max(0, bounds.width - 4), height: max(0, bounds.height - 35))
    titleLabel?.textAlignment = .center
    titleLabel?.adjustsFontSizeToFitWidth = true
    titleLabel?.minimumScaleFactor = 0.7
  }

  override func accessibilityActivate() -> Bool {
    sendActions(for: .touchUpInside)
    return true
  }
}
