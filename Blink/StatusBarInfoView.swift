////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2019 Blink Mobile Shell Project
//
// This file is part of Blink.
//
// Blink is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Blink is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Blink. If not, see <http://www.gnu.org/licenses/>.
//
// In addition, Blink is also subject to certain additional terms under
// GNU GPL version 3 section 7.
//
// You should have received a copy of these additional terms immediately
// following the terms and conditions of the GNU General Public License
// which accompanied the Blink Source Code. If not, see
// <http://www.github.com/blinksh/blink>.
//
////////////////////////////////////////////////////////////////////////////////

import UIKit

class StatusBarInfoView: UIView {

  private let leftLabel = UILabel()
  private let rightLabel = UILabel()
  private let statusDot = UIView()

  private let horizontalMargin: CGFloat = 16
  private let dotSize: CGFloat = 6

  private var _clockTimer: Timer?
  private var _sessionStartTime: Date?
  private var _isRunningCmd: Bool = false
  private var _isLightBg: Bool = false

  private lazy var _clockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()

  // Cached state for rebuilding attributed strings on clock tick
  private var _windowIndex: Int = 0
  private var _windowCount: Int = 0
  private var _parsedUser: String?
  private var _parsedHost: String?
  private var _rawTitle: String?

  // HUD decoration layers
  private let hudContainerLayer = CALayer()
  private let frameLinesLayer = CAShapeLayer()
  private let tickMarksLayer = CAShapeLayer()
  private let bracketMarkersLayer = CAShapeLayer()
  private let leftScanLine = CAGradientLayer()
  private let rightScanLine = CAGradientLayer()
  private let leftDataStream = CAReplicatorLayer()
  private let rightDataStream = CAReplicatorLayer()
  private let leftDotTemplate = CALayer()
  private let rightDotTemplate = CALayer()

  // Track center exclusion for HUD animations
  private var _centerExclusion: CGFloat = 0
  private var _lastLayoutSize: CGSize = .zero
  private var _hudAnimationsRunning = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    _setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    _setup()
  }

  private func _setup() {
    isUserInteractionEnabled = false
    backgroundColor = .clear

    let font = UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)

    leftLabel.font = font
    leftLabel.lineBreakMode = .byTruncatingTail

    rightLabel.font = font
    rightLabel.textAlignment = .right
    rightLabel.lineBreakMode = .byTruncatingTail

    statusDot.layer.cornerRadius = dotSize / 2
    statusDot.backgroundColor = UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0)

    // HUD container — behind all subviews
    hudContainerLayer.masksToBounds = true
    layer.addSublayer(hudContainerLayer)

    // Static shape layers
    frameLinesLayer.fillColor = nil
    frameLinesLayer.lineWidth = 1.0
    hudContainerLayer.addSublayer(frameLinesLayer)

    tickMarksLayer.fillColor = nil
    tickMarksLayer.lineWidth = 1.0
    hudContainerLayer.addSublayer(tickMarksLayer)

    bracketMarkersLayer.fillColor = nil
    bracketMarkersLayer.lineWidth = 1.0
    bracketMarkersLayer.lineCap = .square
    hudContainerLayer.addSublayer(bracketMarkersLayer)

    // Scan lines — gradient layers
    let scanLineHeight: CGFloat = 2
    let scanLineWidth: CGFloat = 60
    for scanLine in [leftScanLine, rightScanLine] {
      scanLine.bounds = CGRect(x: 0, y: 0, width: scanLineWidth, height: scanLineHeight)
      scanLine.startPoint = CGPoint(x: 0, y: 0.5)
      scanLine.endPoint = CGPoint(x: 1, y: 0.5)
      scanLine.locations = [0, 0.3, 0.7, 1.0] as [NSNumber]
      hudContainerLayer.addSublayer(scanLine)
    }

    // Data stream replicators
    let dotSpacing: CGFloat = 6
    let dotDiameter: CGFloat = 2.5

    leftDotTemplate.bounds = CGRect(x: 0, y: 0, width: dotDiameter, height: dotDiameter)
    leftDotTemplate.cornerRadius = dotDiameter / 2
    leftDataStream.instanceTransform = CATransform3DMakeTranslation(dotSpacing, 0, 0)
    leftDataStream.masksToBounds = true
    leftDataStream.addSublayer(leftDotTemplate)
    hudContainerLayer.addSublayer(leftDataStream)

    rightDotTemplate.bounds = CGRect(x: 0, y: 0, width: dotDiameter, height: dotDiameter)
    rightDotTemplate.cornerRadius = dotDiameter / 2
    rightDataStream.instanceTransform = CATransform3DMakeTranslation(-dotSpacing, 0, 0)
    rightDataStream.masksToBounds = true
    rightDataStream.addSublayer(rightDotTemplate)
    hudContainerLayer.addSublayer(rightDataStream)

    addSubview(statusDot)
    addSubview(leftLabel)
    addSubview(rightLabel)

    _updateHUDColors()

    NotificationCenter.default.addObserver(
      self, selector: #selector(_appWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(_appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
  }

  deinit {
    _clockTimer?.invalidate()
    NotificationCenter.default.removeObserver(self)
  }

  override func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)
    if newSuperview != nil {
      _startClockTimer()
      _startPulseAnimation()
      _startHUDAnimations()
    } else {
      _clockTimer?.invalidate()
      _clockTimer = nil
      _hudAnimationsRunning = false
    }
  }

  @objc private func _appWillEnterForeground() {
    _startClockTimer()
    _startPulseAnimation()
    _startHUDAnimations()
    _rebuildLabels()
  }

  @objc private func _appDidEnterBackground() {
    _clockTimer?.invalidate()
    _clockTimer = nil
    _hudAnimationsRunning = false
  }

  // MARK: - Public

  func update(windowIndex: Int, windowCount: Int, title: String?,
              bgColor: UIColor?, isRunningCmd: Bool, sessionStartTime: Date?) {
    _isLightBg = bgColor?.isLight ?? false
    _windowIndex = windowIndex
    _windowCount = windowCount
    _isRunningCmd = isRunningCmd
    _sessionStartTime = sessionStartTime

    let (user, host) = _parseTitleComponents(title)
    _parsedUser = user
    _parsedHost = host
    _rawTitle = title

    _updatePulseSpeed()
    _updateHUDColors()
    _rebuildLabels()
    setNeedsLayout()
  }

  // MARK: - Color Palette

  private var _primaryColor: UIColor {
    _isLightBg
      ? UIColor.black.withAlphaComponent(0.55)
      : UIColor.white.withAlphaComponent(0.6)
  }

  private var _accentColor: UIColor {
    _isLightBg
      ? UIColor(red: 0.0, green: 0.45, blue: 0.65, alpha: 0.8)
      : UIColor(red: 0.3, green: 0.85, blue: 1.0, alpha: 0.85)
  }

  private var _dimColor: UIColor {
    _isLightBg
      ? UIColor.black.withAlphaComponent(0.25)
      : UIColor.white.withAlphaComponent(0.3)
  }

  private var _hudCyanColor: UIColor {
    _isLightBg
      ? UIColor(red: 0.0, green: 0.48, blue: 0.55, alpha: 0.65)
      : UIColor(red: 0.3, green: 0.85, blue: 0.91, alpha: 0.60)
  }

  private var _hudAmberColor: UIColor {
    _isLightBg
      ? UIColor(red: 0.7, green: 0.45, blue: 0.0, alpha: 0.55)
      : UIColor(red: 1.0, green: 0.7, blue: 0.2, alpha: 0.50)
  }

  private var _hudPurpleColor: UIColor {
    _isLightBg
      ? UIColor(red: 0.45, green: 0.15, blue: 0.6, alpha: 0.55)
      : UIColor(red: 0.7, green: 0.4, blue: 1.0, alpha: 0.50)
  }

  private var _hudGreenColor: UIColor {
    _isLightBg
      ? UIColor(red: 0.1, green: 0.48, blue: 0.2, alpha: 0.50)
      : UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 0.45)
  }

  private var _hudFrameColor: UIColor {
    _isLightBg
      ? UIColor.black.withAlphaComponent(0.25)
      : UIColor.white.withAlphaComponent(0.25)
  }

  // MARK: - HUD Colors

  private func _updateHUDColors() {
    let frameColor = _hudFrameColor.cgColor
    frameLinesLayer.strokeColor = frameColor

    let tickColor = _isLightBg
      ? UIColor.black.withAlphaComponent(0.35).cgColor
      : UIColor.white.withAlphaComponent(0.30).cgColor
    tickMarksLayer.strokeColor = tickColor

    // Brackets — purple
    bracketMarkersLayer.strokeColor = _hudPurpleColor.cgColor

    // Left scan line — cyan
    let clearColor = UIColor.clear.cgColor
    let cyanCG = _hudCyanColor.cgColor
    leftScanLine.colors = [clearColor, cyanCG, cyanCG, clearColor]

    // Right scan line — amber
    let amberCG = _hudAmberColor.cgColor
    rightScanLine.colors = [clearColor, amberCG, amberCG, clearColor]

    // Left data dots — green, right data dots — amber
    leftDotTemplate.backgroundColor = _hudGreenColor.cgColor
    rightDotTemplate.backgroundColor = _hudAmberColor.cgColor
  }

  // MARK: - Title Parsing

  private func _parseTitleComponents(_ title: String?) -> (user: String?, host: String?) {
    guard let title = title, !title.isEmpty else { return (nil, nil) }

    // Match "user@host" or "user@host: path" or "user@host:path"
    guard let atIndex = title.firstIndex(of: "@") else { return (nil, nil) }

    let user = String(title[title.startIndex..<atIndex])
    let afterAt = title[title.index(after: atIndex)...]

    let host: String
    if let endIndex = afterAt.firstIndex(where: { $0 == ":" || $0 == " " }) {
      host = String(afterAt[afterAt.startIndex..<endIndex])
    } else {
      host = String(afterAt)
    }

    return (user.isEmpty ? nil : user, host.isEmpty ? nil : host)
  }

  // MARK: - Label Building

  private func _rebuildLabels() {
    leftLabel.attributedText = _buildLeftAttributedString()
    rightLabel.attributedText = _buildRightAttributedString()
  }

  private func _buildLeftAttributedString() -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)

    // Window counter (only if multiple windows)
    if _windowCount > 1 {
      result.append(NSAttributedString(
        string: "▸ ",
        attributes: [.foregroundColor: _dimColor, .font: font]))
      result.append(NSAttributedString(
        string: "\(_windowIndex)/\(_windowCount)",
        attributes: [.foregroundColor: _accentColor, .font: font]))
      result.append(NSAttributedString(
        string: " │ ",
        attributes: [.foregroundColor: _dimColor, .font: font]))
    }

    // Live clock
    let timeStr = _clockFormatter.string(from: Date())
    result.append(NSAttributedString(
      string: timeStr,
      attributes: [.foregroundColor: _primaryColor, .font: font]))

    return result
  }

  private func _buildRightAttributedString() -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)

    // Host info — prefer parsed user@host, fall back to raw terminal title
    let hostDisplay: String
    if let user = _parsedUser, let host = _parsedHost {
      hostDisplay = "\(user)@\(host)"
    } else if let host = _parsedHost {
      hostDisplay = host
    } else if let title = _rawTitle, !title.isEmpty {
      hostDisplay = title
    } else {
      hostDisplay = "blink"
    }

    result.append(NSAttributedString(
      string: hostDisplay,
      attributes: [.foregroundColor: _accentColor, .font: font]))

    // Uptime
    if let startTime = _sessionStartTime {
      result.append(NSAttributedString(
        string: " │ ",
        attributes: [.foregroundColor: _dimColor, .font: font]))
      let uptimeStr = _formatUptime(since: startTime)
      result.append(NSAttributedString(
        string: "↑\(uptimeStr)",
        attributes: [.foregroundColor: _primaryColor, .font: font]))
    }

    return result
  }

  // MARK: - Uptime

  private func _formatUptime(since startTime: Date) -> String {
    let elapsed = Int(Date().timeIntervalSince(startTime))
    if elapsed < 60 {
      return "\(elapsed)s"
    } else if elapsed < 3600 {
      return "\(elapsed / 60)m"
    } else {
      let h = elapsed / 3600
      let m = (elapsed % 3600) / 60
      return "\(h)h\(m)m"
    }
  }

  // MARK: - Clock Timer

  private func _startClockTimer() {
    _clockTimer?.invalidate()
    _clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      self?._rebuildLabels()
    }
  }

  // MARK: - Pulse Animation

  private func _startPulseAnimation() {
    statusDot.layer.removeAnimation(forKey: "pulse")
    let anim = CABasicAnimation(keyPath: "opacity")
    anim.fromValue = 1.0
    anim.toValue = 0.3
    anim.duration = _isRunningCmd ? 0.5 : 1.8
    anim.autoreverses = true
    anim.repeatCount = .infinity
    anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    statusDot.layer.add(anim, forKey: "pulse")
  }

  private func _updatePulseSpeed() {
    _startPulseAnimation()
  }

  // MARK: - HUD Animations

  private func _startHUDAnimations() {
    let hudStart = horizontalMargin
    let hudEnd = bounds.width - horizontalMargin
    let fullWidth = hudEnd - hudStart
    guard fullWidth > 40 else { return }

    let scanLineWidth: CGFloat = 60

    // Scan lines — continuous one-directional sweep
    // Enter fully off-screen one side, exit fully off-screen the other,
    // then loop. Since beam is invisible at both ends, the reset is invisible.
    let scanDurationL: CFTimeInterval = _isRunningCmd ? 2.5 : 5.0
    let scanDurationR: CFTimeInterval = _isRunningCmd ? 3.0 : 6.0

    leftScanLine.removeAnimation(forKey: "scan")
    let animL = CABasicAnimation(keyPath: "position.x")
    animL.fromValue = hudStart - scanLineWidth
    animL.toValue = hudEnd + scanLineWidth
    animL.duration = scanDurationL
    animL.repeatCount = .infinity
    animL.timingFunction = CAMediaTimingFunction(name: .linear)
    leftScanLine.add(animL, forKey: "scan")

    rightScanLine.removeAnimation(forKey: "scan")
    let animR = CABasicAnimation(keyPath: "position.x")
    animR.fromValue = hudEnd + scanLineWidth
    animR.toValue = hudStart - scanLineWidth
    animR.duration = scanDurationR
    animR.repeatCount = .infinity
    animR.timingFunction = CAMediaTimingFunction(name: .linear)
    rightScanLine.add(animR, forKey: "scan")

    // Bracket marker pulse
    bracketMarkersLayer.removeAnimation(forKey: "pulse")
    let bracketAnim = CABasicAnimation(keyPath: "opacity")
    bracketAnim.fromValue = 0.5
    bracketAnim.toValue = 0.15
    bracketAnim.duration = 3.0
    bracketAnim.autoreverses = true
    bracketAnim.repeatCount = .infinity
    bracketAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    bracketMarkersLayer.add(bracketAnim, forKey: "pulse")

    // Data stream scroll — single-spacing seamless loop
    // Each stream shifts by exactly one dot-spacing, then resets.
    // The pattern tiles perfectly so the reset is invisible.
    let dotSpacing: CGFloat = 6

    leftDataStream.removeAnimation(forKey: "scroll")
    let scrollAnimL = CABasicAnimation(keyPath: "sublayerTransform.translation.x")
    scrollAnimL.fromValue = 0
    scrollAnimL.toValue = dotSpacing
    scrollAnimL.duration = 0.8
    scrollAnimL.repeatCount = .infinity
    scrollAnimL.timingFunction = CAMediaTimingFunction(name: .linear)
    leftDataStream.add(scrollAnimL, forKey: "scroll")

    rightDataStream.removeAnimation(forKey: "scroll")
    let scrollAnimR = CABasicAnimation(keyPath: "sublayerTransform.translation.x")
    scrollAnimR.fromValue = 0
    scrollAnimR.toValue = -dotSpacing
    scrollAnimR.duration = 0.8
    scrollAnimR.repeatCount = .infinity
    scrollAnimR.timingFunction = CAMediaTimingFunction(name: .linear)
    rightDataStream.add(scrollAnimR, forKey: "scroll")

    _hudAnimationsRunning = true
  }

  // MARK: - HUD Path Builders

  private func _buildFrameLinesPath(
    start: CGFloat, end: CGFloat, hudHeight: CGFloat
  ) -> UIBezierPath {
    let path = UIBezierPath()

    // Top line — full width
    path.move(to: CGPoint(x: start, y: 1))
    path.addLine(to: CGPoint(x: end, y: 1))

    // Bottom line — full width, just above label zone
    path.move(to: CGPoint(x: start, y: hudHeight - 1))
    path.addLine(to: CGPoint(x: end, y: hudHeight - 1))

    return path
  }

  private func _buildTickMarksPath(
    start: CGFloat, end: CGFloat
  ) -> UIBezierPath {
    let path = UIBezierPath()
    let tickSpacing: CGFloat = 8
    let minorHeight: CGFloat = 3
    let majorHeight: CGFloat = 5
    let topY: CGFloat = 2

    var x = start
    var idx = 0
    while x <= end {
      let h = (idx % 4 == 0) ? majorHeight : minorHeight
      path.move(to: CGPoint(x: x, y: topY))
      path.addLine(to: CGPoint(x: x, y: topY + h))
      x += tickSpacing
      idx += 1
    }

    return path
  }

  private func _buildBracketMarkersPath(
    start: CGFloat, end: CGFloat, hudHeight: CGFloat
  ) -> UIBezierPath {
    let path = UIBezierPath()
    let size: CGFloat = 8

    func bracket(corner: CGPoint, hDir: CGFloat, vDir: CGFloat) {
      path.move(to: CGPoint(x: corner.x + hDir * size, y: corner.y))
      path.addLine(to: corner)
      path.addLine(to: CGPoint(x: corner.x, y: corner.y + vDir * size))
    }

    // Four corners of the full-width HUD zone
    bracket(corner: CGPoint(x: start, y: 2), hDir: 1, vDir: 1)
    bracket(corner: CGPoint(x: end, y: 2), hDir: -1, vDir: 1)
    bracket(corner: CGPoint(x: start, y: hudHeight - 2), hDir: 1, vDir: -1)
    bracket(corner: CGPoint(x: end, y: hudHeight - 2), hDir: -1, vDir: -1)

    return path
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()

    let device = DeviceInfo.shared()
    let centerExclusion: CGFloat
    if device.hasDynamicIsland {
      centerExclusion = 125
    } else if device.hasNotch {
      centerExclusion = 215
    } else {
      centerExclusion = 0
    }
    _centerExclusion = centerExclusion

    let halfExclusion = centerExclusion / 2
    let midX = bounds.width / 2
    let labelHeight: CGFloat = 16
    let labelY = bounds.height - labelHeight - 7

    // Status dot — left edge, vertically centered with labels
    let dotX = horizontalMargin
    let dotY = labelY + (labelHeight - dotSize) / 2
    statusDot.frame = CGRect(x: dotX, y: dotY, width: dotSize, height: dotSize)

    // Left label — after dot
    let leftX = dotX + dotSize + 6
    let leftWidth = midX - halfExclusion - leftX
    leftLabel.frame = CGRect(
      x: leftX,
      y: labelY,
      width: max(leftWidth, 0),
      height: labelHeight
    )

    // Right label
    let rightX = midX + halfExclusion
    let rightWidth = midX - halfExclusion - horizontalMargin
    rightLabel.frame = CGRect(
      x: rightX,
      y: labelY,
      width: max(rightWidth, 0),
      height: labelHeight
    )

    // MARK: HUD Layout
    let hudHeight = bounds.height - 25
    hudContainerLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(hudHeight, 0))

    if hudHeight < 5 {
      hudContainerLayer.isHidden = true
      return
    }
    hudContainerLayer.isHidden = false

    // HUD elements span the FULL width (render behind the Dynamic Island)
    let hudStart = horizontalMargin
    let hudEnd = bounds.width - horizontalMargin
    let fullWidth = hudEnd - hudStart

    // Disable implicit animations for layout changes
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    // Frame lines — full width
    frameLinesLayer.frame = hudContainerLayer.bounds
    frameLinesLayer.path = _buildFrameLinesPath(
      start: hudStart, end: hudEnd, hudHeight: hudHeight
    ).cgPath

    // Tick marks — full width
    tickMarksLayer.frame = hudContainerLayer.bounds
    tickMarksLayer.path = _buildTickMarksPath(
      start: hudStart, end: hudEnd
    ).cgPath

    // Bracket markers — at the four corners
    bracketMarkersLayer.frame = hudContainerLayer.bounds
    bracketMarkersLayer.path = _buildBracketMarkersPath(
      start: hudStart, end: hudEnd, hudHeight: hudHeight
    ).cgPath
    bracketMarkersLayer.isHidden = false

    // Scan lines — position at y=8, sweep full width
    let scanY: CGFloat = min(8, hudHeight / 2)
    leftScanLine.position = CGPoint(x: midX, y: scanY)
    rightScanLine.position = CGPoint(x: midX, y: scanY + 10)

    // Data streams — full width, seamless scrolling
    let dotSpacing: CGFloat = 6
    let dotDiameter: CGFloat = 2.5
    let streamY: CGFloat = min(18, hudHeight - 4)

    if fullWidth > 0 {
      let visibleDots = Int(fullWidth / dotSpacing) + 3

      // Left stream (scrolls right) — template one spacing off-screen left,
      // instances replicate rightward. Shifting right by one spacing tiles perfectly.
      leftDataStream.isHidden = false
      leftDataStream.frame = CGRect(
        x: hudStart, y: streamY - dotDiameter / 2,
        width: fullWidth, height: dotDiameter)
      leftDotTemplate.position = CGPoint(x: -dotSpacing + dotDiameter / 2, y: dotDiameter / 2)
      leftDataStream.instanceCount = visibleDots

      // Right stream (scrolls left) — template one spacing off-screen right,
      // instances replicate leftward (negative instanceTransform). Shifting left
      // by one spacing tiles perfectly.
      rightDataStream.isHidden = false
      rightDataStream.frame = CGRect(
        x: hudStart, y: streamY - dotDiameter / 2 + 6,
        width: fullWidth, height: dotDiameter)
      rightDotTemplate.position = CGPoint(x: fullWidth + dotSpacing - dotDiameter / 2, y: dotDiameter / 2)
      rightDataStream.instanceCount = visibleDots
    } else {
      leftDataStream.isHidden = true
      rightDataStream.isHidden = true
    }

    CATransaction.commit()

    // Only restart HUD animations when the view size actually changes
    if _lastLayoutSize != bounds.size || !_hudAnimationsRunning {
      _lastLayoutSize = bounds.size
      _startHUDAnimations()
    }
  }
}
