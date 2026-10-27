import Flutter
import QuartzCore
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
  // Keep the moving glass beside the base material so its expanded edge isn't clipped.
  private let surface = UIView()
  private let material = UIVisualEffectView(effect: nil)
  private let lens = UIVisualEffectView(effect: nil)
  private let symbols = ["house", "cloud", "books.vertical", "safari", "square.grid.2x2"]
  private let filledSymbols = [
    "house.fill", "cloud.fill", "books.vertical.fill", "safari.fill", "square.grid.2x2.fill",
  ]
  private var buttons: [DCikeTabButton] = []
  private var selectedIndex = 0
  private var previewIndex = 0
  private var dragging = false
  private var dragX: CGFloat?
  private var dragY: CGFloat = 0
  private var lastDragPoint = CGPoint.zero
  private var lastDragTime: CFTimeInterval = 0
  private var dragVelocity: CGFloat = 0
  private var lensAnimator: UIViewPropertyAnimator?
  private var laidOutRtl: Bool?
  private var isRtl = false
  private var darkMode = false
  private var materialDarkMode: Bool?
  private let feedback = UISelectionFeedbackGenerator()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    surface.backgroundColor = .clear
    surface.clipsToBounds = false
    material.isUserInteractionEnabled = false
    material.clipsToBounds = true
    lens.isUserInteractionEnabled = false
    lens.clipsToBounds = true
    addSubview(surface)
    surface.addSubview(material)
    surface.addSubview(lens)
    for index in symbols.indices {
      let button = DCikeTabButton(type: .custom)
      button.tag = index
      button.addTarget(self, action: #selector(activate(_:)), for: .touchUpInside)
      surface.addSubview(button)
      buttons.append(button)
    }
    let gesture = UILongPressGestureRecognizer(target: self, action: #selector(trackSelection(_:)))
    gesture.minimumPressDuration = 0
    gesture.allowableMovement = .greatestFiniteMagnitude
    surface.addGestureRecognizer(gesture)
    NotificationCenter.default.addObserver(
      self, selector: #selector(accessibilityChanged),
      name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(accessibilityChanged),
      name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil
    )
    refreshMaterial()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    lensAnimator?.stopAnimation(true)
    NotificationCenter.default.removeObserver(self)
  }

  func configure(_ values: [String: Any]) {
    let previousSelection = selectedIndex
    let previousRtl = isRtl
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
    if previousRtl != isRtl || surface.bounds.isEmpty {
      setNeedsLayout()
    } else if !dragging && previousSelection != selectedIndex {
      settleLens(velocity: 0)
    }
    // Flutter acknowledges a selection immediately. An unchanged acknowledgement
    // must not relayout the lens and replace its in-flight spring with the end frame.
  }

  @objc private func accessibilityChanged() {
    refreshMaterial()
    if UIAccessibility.isReduceMotionEnabled {
      interruptLensAnimation()
      positionLens(centerX: dragX)
      lens.transform = .identity
      updatePressedSymbols()
    }
  }

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
    // Reserve room for the expanded lens inside Flutter's platform-view boundary.
    let width = min(520, max(0, bounds.width - 32))
    let surfaceFrame = CGRect(x: (bounds.width - width) / 2, y: 8, width: width, height: max(0, bounds.height - 16))
    guard surface.frame != surfaceFrame || laidOutRtl != isRtl else { return }
    interruptLensAnimation()
    surface.frame = surfaceFrame
    material.frame = surface.bounds
    laidOutRtl = isRtl
    material.layer.cornerRadius = material.bounds.height / 2
    material.layer.cornerCurve = .continuous
    layer.shadowPath = UIBezierPath(roundedRect: surface.frame, cornerRadius: material.layer.cornerRadius).cgPath
    let itemWidth = max(0, (surface.bounds.width - 8) / CGFloat(buttons.count))
    for (index, button) in buttons.enumerated() {
      let visualIndex = isRtl ? buttons.count - 1 - index : index
      button.frame = CGRect(x: 4 + CGFloat(visualIndex) * itemWidth, y: 4, width: itemWidth, height: max(0, surface.bounds.height - 8))
    }
    lens.transform = .identity
    positionLens(centerX: dragX)
    lens.transform = dragging ? pressedLensTransform() : .identity
    updatePressedSymbols()
  }

  private func lensCenter(centerX: CGFloat? = nil) -> CGPoint {
    let rect = buttons[previewIndex].frame
    guard let centerX = centerX else { return CGPoint(x: rect.midX, y: rect.midY) }
    let minimum = 4 + rect.width / 2
    let maximum = max(minimum, surface.bounds.width - 4 - rect.width / 2)
    let clamped = min(maximum, max(minimum, centerX))
    let expansion = rect.width * 0.32 / 2
    let edgeSpace = surface.frame.minX + 4
    let overdragLimit = min(8, max(1, edgeSpace - expansion - 2))
    // A bounded overdrag gives the ends resistance instead of a hard stop.
    return CGPoint(x: clamped + rubberBand(centerX - clamped, limit: overdragLimit),
                   y: rect.midY + rubberBand(dragY, limit: 3))
  }

  private func positionLens(centerX: CGFloat? = nil) {
    guard buttons.indices.contains(previewIndex) else { return }
    let rect = buttons[previewIndex].frame
    lens.bounds = CGRect(origin: .zero, size: rect.size)
    lens.center = lensCenter(centerX: centerX)
    lens.layer.cornerRadius = rect.height / 2
    lens.layer.cornerCurve = .continuous
  }

  private func rubberBand(_ distance: CGFloat, limit: CGFloat) -> CGFloat {
    let magnitude = abs(distance)
    return (distance < 0 ? -1 : 1) * limit * magnitude / (magnitude + limit / 0.55)
  }

  private func pressedLensTransform() -> CGAffineTransform {
    guard !UIAccessibility.isReduceMotionEnabled else { return .identity }
    let stretch = min(0.18, abs(dragVelocity) / 7000)
    return CGAffineTransform(scaleX: 1.14 + stretch, y: 1.16 - stretch * 0.3)
  }

  private func updatePressedSymbols() {
    for (index, button) in buttons.enumerated() {
      let scale: CGFloat = dragging && index == previewIndex && !UIAccessibility.isReduceMotionEnabled ? 1.10 : 1
      button.imageView?.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
  }

  private func interruptLensAnimation() {
    let position = lens.layer.presentation()?.position
    let transform = lens.layer.presentation()?.affineTransform()
    let imageTransforms = buttons.map { $0.imageView?.layer.presentation()?.affineTransform() }
    lensAnimator?.stopAnimation(true)
    lensAnimator = nil
    UIView.performWithoutAnimation {
      if let position = position { lens.center = position }
      if let transform = transform { lens.transform = transform }
      for (index, button) in buttons.enumerated() {
        if let imageTransform = imageTransforms[index] { button.imageView?.transform = imageTransform }
      }
    }
  }

  private func animateLens(to center: CGPoint, transform: CGAffineTransform,
                           duration: TimeInterval, damping: CGFloat, velocity: CGFloat = 0) {
    interruptLensAnimation()
    let changes = { [weak self] in
      guard let self = self else { return }
      self.lens.center = center
      self.lens.transform = transform
      self.updatePressedSymbols()
    }
    guard !UIAccessibility.isReduceMotionEnabled, window != nil else {
      changes()
      return
    }
    let distance = center.x - lens.center.x
    let relativeVelocity = abs(distance) > 1 ? min(8, max(-8, velocity / distance)) : 0
    let spring = UISpringTimingParameters(dampingRatio: damping,
                                         initialVelocity: CGVector(dx: relativeVelocity, dy: 0))
    let animator = UIViewPropertyAnimator(duration: duration, timingParameters: spring)
    animator.addAnimations(changes)
    animator.addCompletion { [weak self, weak animator] _ in
      guard let self = self, self.lensAnimator === animator else { return }
      self.lensAnimator = nil
    }
    lensAnimator = animator
    animator.startAnimation()
  }

  private func settleLens(velocity: CGFloat) {
    guard !surface.bounds.isEmpty else { return }
    animateLens(to: lensCenter(), transform: .identity,
                duration: 0.62, damping: 0.56, velocity: min(1800, max(-1800, velocity)))
  }

  private func index(at x: CGFloat) -> Int {
    let width = max(1, (surface.bounds.width - 8) / CGFloat(buttons.count))
    let slot = min(buttons.count - 1, max(0, Int(floor((x - 4) / width))))
    return isRtl ? buttons.count - 1 - slot : slot
  }

  @objc private func trackSelection(_ gesture: UILongPressGestureRecognizer) {
    let point = gesture.location(in: surface)
    switch gesture.state {
    case .began:
      dragging = true
      dragVelocity = 0
      lastDragPoint = point
      lastDragTime = CACurrentMediaTime()
      feedback.prepare()
      trackLens(at: point, beginning: true)
    case .changed:
      let time = CACurrentMediaTime()
      let interval = max(1.0 / 240.0, time - lastDragTime)
      let velocity = min(4000, max(-4000, (point.x - lastDragPoint.x) / CGFloat(interval)))
      dragVelocity = dragVelocity * 0.65 + velocity * 0.35
      lastDragPoint = point
      lastDragTime = time
      trackLens(at: point, beginning: false)
    case .ended:
      // Dragging far away cancels, just like moving outside a normal control.
      let isInside = surface.bounds.insetBy(dx: -24, dy: -32).contains(point)
      if CACurrentMediaTime() - lastDragTime > 0.12 { dragVelocity = 0 }
      finishSelection(isInside ? index(at: point.x) : selectedIndex, commit: isInside)
    case .cancelled, .failed:
      finishSelection(selectedIndex, commit: false)
    default:
      break
    }
  }

  private func trackLens(at point: CGPoint, beginning: Bool) {
    let next = index(at: point.x)
    if next != previewIndex { feedback.selectionChanged(); feedback.prepare() }
    previewIndex = next
    dragX = point.x
    dragY = point.y - surface.bounds.midY
    updateButtons()
    animateLens(to: lensCenter(centerX: point.x), transform: pressedLensTransform(),
                duration: beginning ? 0.30 : 0.16, damping: beginning ? 0.60 : 0.82,
                velocity: beginning ? 0 : dragVelocity)
  }

  @objc private func activate(_ sender: UIButton) { finishSelection(sender.tag, commit: true) }

  private func finishSelection(_ index: Int, commit: Bool) {
    dragging = false
    dragX = nil
    dragY = 0
    previewIndex = index
    if commit { selectedIndex = index }
    updateButtons()
    settleLens(velocity: dragVelocity)
    dragVelocity = 0
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

/// Native iOS category strip used by plugin home pages. On iOS 26 and later
/// this uses Apple's UIGlassEffect; on earlier systems it uses UIBlurEffect so
/// the same layout remains available without pretending to be Liquid Glass.
final class DCikeGlassHomeCategoriesFactory: NSObject, FlutterPlatformViewFactory {
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
    DCikeGlassHomeCategoriesPlatformView(
      frame: frame, id: viewId, args: args, messenger: messenger
    )
  }
}

private final class DCikeGlassHomeCategoriesPlatformView: NSObject, FlutterPlatformView {
  private let content: DCikeGlassHomeCategories
  private let channel: FlutterMethodChannel

  init(frame: CGRect, id: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
    content = DCikeGlassHomeCategories(frame: frame)
    channel = FlutterMethodChannel(
      name: "dcike/native_home_categories/\(id)", binaryMessenger: messenger
    )
    super.init()
    content.configure(args as? [String: Any] ?? [:])
    content.onSelected = { [weak self] index in
      self?.channel.invokeMethod("selectCategory", arguments: index)
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      guard call.method == "update" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.content.configure(call.arguments as? [String: Any] ?? [:])
      result(nil)
    }
  }

  func view() -> UIView { content }

  deinit { channel.setMethodCallHandler(nil) }
}

private final class DCikeGlassHomeCategories: UIView {
  var onSelected: ((Int) -> Void)?
  private let scrollView = UIScrollView()
  private let material = UIVisualEffectView(effect: nil)
  private let selection = UIVisualEffectView(effect: nil)
  private var buttons: [UIButton] = []
  private var selectedIndex = 0
  private var darkMode = false
  private var labels: [String] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    material.isUserInteractionEnabled = false
    selection.isUserInteractionEnabled = false
    addSubview(material)
    addSubview(scrollView)
    scrollView.backgroundColor = .clear
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.alwaysBounceHorizontal = true
    scrollView.addSubview(selection)
    refreshMaterial()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(_ values: [String: Any]) {
    labels = values["labels"] as? [String] ?? []
    selectedIndex = max(0, min(labels.count - 1, values["selectedIndex"] as? Int ?? 0))
    darkMode = values["darkMode"] as? Bool ?? false
    overrideUserInterfaceStyle = darkMode ? .dark : .light
    refreshMaterial()
    rebuildButtons()
    setNeedsLayout()
  }

  private func refreshMaterial() {
    if UIAccessibility.isReduceTransparencyEnabled {
      material.effect = nil
      selection.effect = nil
      material.backgroundColor = .secondarySystemBackground
      selection.backgroundColor = .tertiarySystemFill
    } else if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      material.effect = glass
      let lens = UIGlassEffect(style: .clear)
      lens.isInteractive = true
      lens.tintColor = UIColor.systemBlue.withAlphaComponent(darkMode ? 0.32 : 0.18)
      selection.effect = lens
      material.backgroundColor = .clear
      selection.backgroundColor = .clear
    } else {
      material.effect = UIBlurEffect(style: darkMode ? .systemMaterialDark : .systemMaterial)
      selection.effect = UIBlurEffect(style: .systemThickMaterial)
      material.backgroundColor = .clear
      selection.backgroundColor = UIColor.systemBlue.withAlphaComponent(darkMode ? 0.28 : 0.16)
    }
    material.layer.cornerCurve = .continuous
    selection.layer.cornerCurve = .continuous
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = darkMode ? 0.22 : 0.1
    layer.shadowRadius = 8
    layer.shadowOffset = CGSize(width: 0, height: 2)
  }

  private func rebuildButtons() {
    for button in buttons { button.removeFromSuperview() }
    buttons.removeAll(keepingCapacity: true)
    for (index, label) in labels.enumerated() {
      let button = UIButton(type: .system)
      button.tag = index
      button.setTitle(label, for: .normal)
      button.setTitleColor(.label, for: .normal)
      button.titleLabel?.font = .systemFont(ofSize: 15, weight: index == selectedIndex ? .semibold : .medium)
      button.accessibilityLabel = label
      button.addTarget(self, action: #selector(selectButton(_:)), for: .touchUpInside)
      scrollView.addSubview(button)
      buttons.append(button)
    }
  }

  @objc private func selectButton(_ sender: UIButton) {
    selectedIndex = sender.tag
    updateButtonStyles(animated: true)
    onSelected?(selectedIndex)
  }

  private func updateButtonStyles(animated: Bool) {
    guard buttons.indices.contains(selectedIndex) else { return }
    let selectedFrame = buttons[selectedIndex].frame.insetBy(dx: -8, dy: -3)
    let changes = { [weak self] in
      guard let self = self else { return }
      self.selection.frame = selectedFrame
      self.selection.layer.cornerRadius = selectedFrame.height / 2
      self.selection.layer.cornerCurve = .continuous
      for (index, button) in self.buttons.enumerated() {
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: index == self.selectedIndex ? .semibold : .medium)
        button.setTitleColor(index == self.selectedIndex ? .label : .secondaryLabel, for: .normal)
      }
    }
    if animated && !UIAccessibility.isReduceMotionEnabled {
      UIView.animate(withDuration: 0.26, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: changes)
    } else {
      changes()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let frame = bounds.insetBy(dx: 8, dy: 4)
    material.frame = frame
    material.layer.cornerRadius = frame.height / 2
    scrollView.frame = frame.insetBy(dx: 4, dy: 3)
    var x: CGFloat = 8
    let height = scrollView.bounds.height
    for button in buttons {
      let width = max(46, button.intrinsicContentSize.width + 20)
      button.frame = CGRect(x: x, y: 0, width: width, height: height)
      x += width + 2
    }
    scrollView.contentSize = CGSize(width: x + 8, height: height)
    updateButtonStyles(animated: false)
    if buttons.indices.contains(selectedIndex) {
      let visible = scrollView.convert(buttons[selectedIndex].frame, from: scrollView)
      if visible.minX < 0 || visible.maxX > scrollView.bounds.width {
        scrollView.scrollRectToVisible(buttons[selectedIndex].frame, animated: false)
      }
    }
    layer.shadowPath = UIBezierPath(roundedRect: material.frame, cornerRadius: material.layer.cornerRadius).cgPath
  }
}

private final class DCikeTabButton: UIButton {
  override func layoutSubviews() {
    super.layoutSubviews()
    // Bounds/center remain well-defined while the icon is scaled by its spring.
    imageView?.bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
    imageView?.center = CGPoint(x: bounds.width / 2, y: 19)
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
