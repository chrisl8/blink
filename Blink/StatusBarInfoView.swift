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
import Network

class StatusBarInfoView: UIView {

  // MARK: - First-line views

  private let leftLabel = UILabel()
  private let rightLabel = UILabel()
  private let statusDot = UIView()

  private let horizontalMargin: CGFloat = 16
  private let dotSize: CGFloat = 6

  private var _clockTimer: Timer?
  private var _chipTimer: Timer?
  private var _sessionStartTime: Date?
  private var _isRunningCmd: Bool = false
  private var _isLightBg: Bool = false

  private lazy var _clockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()

  private lazy var _dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM/dd"
    return f
  }()

  // Cached state for rebuilding attributed strings on clock tick
  private var _windowIndex: Int = 0
  private var _windowCount: Int = 0
  private var _parsedUser: String?
  private var _parsedHost: String?
  private var _rawTitle: String?
  private var _hostAlias: String?

  // First-line change tracking (for animations)
  private var _prevWindowIndex: Int = -1
  private var _prevWindowCount: Int = -1
  private var _prevHostDisplay: String = ""
  private var _prevMinute: Int = -1

  // MARK: - Status chips

  private enum ChipKind: Int, CaseIterable {
    case battery, network, memory, thermal, sysUptime, date
  }

  private var chipLabels: [ChipKind: UILabel] = [:]
  private var chipValues: [ChipKind: String] = [:]
  private var chipSeverity: [ChipKind: Int] = [:]

  private let netMonitor = NWPathMonitor()
  private var netStatusString: String = "..."
  private var netStatusSeverity: Int = 0

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

    addSubview(statusDot)
    addSubview(leftLabel)
    addSubview(rightLabel)

    // Build chip labels
    let chipFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)
    for kind in ChipKind.allCases {
      let l = UILabel()
      l.font = chipFont
      l.textAlignment = .center
      l.lineBreakMode = .byClipping
      l.text = " "
      addSubview(l)
      chipLabels[kind] = l
      chipValues[kind] = ""
      chipSeverity[kind] = 0
    }

    UIDevice.current.isBatteryMonitoringEnabled = true

    NotificationCenter.default.addObserver(
      self, selector: #selector(_appWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(_appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(_chipEventNotification),
      name: UIDevice.batteryStateDidChangeNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(_chipEventNotification),
      name: UIDevice.batteryLevelDidChangeNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(_chipEventNotification),
      name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(_chipEventNotification),
      name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)

    _startNetworkMonitor()
  }

  deinit {
    _clockTimer?.invalidate()
    _chipTimer?.invalidate()
    netMonitor.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  override func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)
    if newSuperview != nil {
      _startClockTimer()
      _startChipTimer()
      _startPulseAnimation()
      _refreshChips(animate: false)
      _startChipBaselineAnimation()
    } else {
      _clockTimer?.invalidate(); _clockTimer = nil
      _chipTimer?.invalidate(); _chipTimer = nil
    }
  }

  @objc private func _appWillEnterForeground() {
    _startClockTimer()
    _startChipTimer()
    _startPulseAnimation()
    _refreshChips(animate: false)
    _startChipBaselineAnimation()
    _rebuildLabels()
  }

  @objc private func _appDidEnterBackground() {
    _clockTimer?.invalidate(); _clockTimer = nil
    _chipTimer?.invalidate(); _chipTimer = nil
  }

  @objc private func _chipEventNotification() {
    DispatchQueue.main.async { [weak self] in
      self?._refreshChips(animate: true)
    }
  }

  // MARK: - Public

  func update(windowIndex: Int, windowCount: Int, title: String?,
              bgColor: UIColor?, isRunningCmd: Bool, sessionStartTime: Date?,
              hostAlias: String?) {
    let newLight = bgColor?.isLight ?? false
    let bgChanged = (_isLightBg != newLight)
    _isLightBg = newLight
    _windowIndex = windowIndex
    _windowCount = windowCount
    _isRunningCmd = isRunningCmd
    _sessionStartTime = sessionStartTime
    _hostAlias = (hostAlias?.isEmpty ?? true) ? nil : hostAlias

    let (user, host) = _parseTitleComponents(title)
    _parsedUser = user
    _parsedHost = host
    _rawTitle = title

    _updatePulseSpeed()
    _rebuildLabels()
    // On bg change, recolor without firing change-pulses
    _refreshChips(animate: !bgChanged)
    setNeedsLayout()
  }

  // MARK: - First-line color palette

  private var _primaryColor: UIColor {
    _isLightBg
      ? UIColor.black.withAlphaComponent(0.6)
      : UIColor.white.withAlphaComponent(0.65)
  }

  private var _dimColor: UIColor {
    _isLightBg
      ? UIColor.black.withAlphaComponent(0.28)
      : UIColor.white.withAlphaComponent(0.32)
  }

  private var _cyanColor: UIColor {
    _isLightBg
      ? UIColor(red: 0.0, green: 0.45, blue: 0.65, alpha: 0.85)
      : UIColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 0.9)
  }

  private var _greenColor: UIColor {
    _isLightBg
      ? UIColor(red: 0.05, green: 0.5, blue: 0.2, alpha: 0.85)
      : UIColor(red: 0.4, green: 0.95, blue: 0.55, alpha: 0.85)
  }

  private var _amberColor: UIColor {
    _isLightBg
      ? UIColor(red: 0.65, green: 0.4, blue: 0.0, alpha: 0.85)
      : UIColor(red: 1.0, green: 0.75, blue: 0.3, alpha: 0.85)
  }

  private var _purpleColor: UIColor {
    _isLightBg
      ? UIColor(red: 0.5, green: 0.2, blue: 0.6, alpha: 0.85)
      : UIColor(red: 0.85, green: 0.6, blue: 1.0, alpha: 0.85)
  }

  // MARK: - Chip color palette

  private func _chipColor(_ kind: ChipKind, severity: Int) -> UIColor {
    switch severity {
    case 1:
      return _isLightBg
        ? UIColor(red: 0.7, green: 0.45, blue: 0.0, alpha: 0.95)
        : UIColor(red: 1.0, green: 0.78, blue: 0.25, alpha: 0.95)
    case 2:
      return _isLightBg
        ? UIColor(red: 0.78, green: 0.15, blue: 0.15, alpha: 0.95)
        : UIColor(red: 1.0, green: 0.42, blue: 0.42, alpha: 0.95)
    default:
      break
    }

    switch kind {
    case .battery:
      return _isLightBg
        ? UIColor(red: 0.1, green: 0.55, blue: 0.2, alpha: 0.85)
        : UIColor(red: 0.45, green: 0.95, blue: 0.55, alpha: 0.78)
    case .network:
      return _isLightBg
        ? UIColor(red: 0.0, green: 0.5, blue: 0.6, alpha: 0.85)
        : UIColor(red: 0.4, green: 0.85, blue: 1.0, alpha: 0.78)
    case .memory:
      return _isLightBg
        ? UIColor(red: 0.5, green: 0.25, blue: 0.65, alpha: 0.85)
        : UIColor(red: 0.85, green: 0.6, blue: 1.0, alpha: 0.78)
    case .thermal:
      return _isLightBg
        ? UIColor(red: 0.55, green: 0.45, blue: 0.05, alpha: 0.85)
        : UIColor(red: 1.0, green: 0.85, blue: 0.4, alpha: 0.78)
    case .sysUptime:
      return _isLightBg
        ? UIColor(red: 0.6, green: 0.3, blue: 0.05, alpha: 0.85)
        : UIColor(red: 1.0, green: 0.7, blue: 0.4, alpha: 0.78)
    case .date:
      return _isLightBg
        ? UIColor(red: 0.4, green: 0.3, blue: 0.55, alpha: 0.8)
        : UIColor(red: 0.78, green: 0.72, blue: 1.0, alpha: 0.75)
    }
  }

  // MARK: - Title parsing

  private func _parseTitleComponents(_ title: String?) -> (user: String?, host: String?) {
    guard let title = title, !title.isEmpty else { return (nil, nil) }

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

  // MARK: - First-line label building

  private func _rebuildLabels() {
    let now = Date()
    let cal = Calendar.current
    let curMinute = cal.component(.minute, from: now)
    let minuteTicked = (_prevMinute != curMinute && _prevMinute != -1)
    _prevMinute = curMinute

    leftLabel.attributedText = _buildLeftAttributedString(now: now)
    rightLabel.attributedText = _buildRightAttributedString()

    // Detect first-line value changes for animations
    let countChanged = (_windowCount != _prevWindowCount && _prevWindowCount != -1)
    let indexChanged = (_windowIndex != _prevWindowIndex && _prevWindowIndex != -1)
    _prevWindowIndex = _windowIndex
    _prevWindowCount = _windowCount

    let hostDisplay = _currentHostDisplay()
    let hostChanged = (hostDisplay != _prevHostDisplay && !_prevHostDisplay.isEmpty)
    _prevHostDisplay = hostDisplay

    if countChanged || indexChanged {
      _flashLabel(leftLabel, scale: 1.18)
    } else if minuteTicked {
      _flashLabel(leftLabel, scale: 1.04)
    }
    if hostChanged {
      _flashLabel(rightLabel, scale: 1.18)
    }
  }

  private func _currentHostDisplay() -> String {
    var parts: [String] = []
    if let alias = _hostAlias { parts.append("≡\(alias)") }
    if let user = _parsedUser, let host = _parsedHost {
      parts.append("\(user)@\(host)")
    } else if let host = _parsedHost {
      parts.append(host)
    } else if parts.isEmpty, let title = _rawTitle, !title.isEmpty {
      parts.append(title)
    }
    return parts.isEmpty ? "blink" : parts.joined(separator: " ")
  }

  private func _buildLeftAttributedString(now: Date) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)

    if _windowCount > 1 {
      result.append(NSAttributedString(
        string: "▸ ",
        attributes: [.foregroundColor: _dimColor, .font: font]))
      result.append(NSAttributedString(
        string: "\(_windowIndex)/\(_windowCount)",
        attributes: [.foregroundColor: _amberColor, .font: font]))
      result.append(NSAttributedString(
        string: " │ ",
        attributes: [.foregroundColor: _dimColor, .font: font]))
    }

    let timeStr = _clockFormatter.string(from: now)
    result.append(NSAttributedString(
      string: timeStr,
      attributes: [.foregroundColor: _greenColor, .font: font]))

    return result
  }

  private func _buildRightAttributedString() -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)

    let hasAlias = _hostAlias != nil
    let aliasMatchesHost: Bool = {
      guard let a = _hostAlias, let h = _parsedHost else { return false }
      return a.caseInsensitiveCompare(h) == .orderedSame
    }()

    if let alias = _hostAlias {
      result.append(NSAttributedString(
        string: "≡",
        attributes: [.foregroundColor: _dimColor, .font: font]))
      result.append(NSAttributedString(
        string: alias,
        attributes: [.foregroundColor: _greenColor, .font: font]))
    }

    let userColor = hasAlias ? _purpleColor.withAlphaComponent(0.55) : _purpleColor
    let hostColor = hasAlias ? _cyanColor.withAlphaComponent(0.55) : _cyanColor

    if let user = _parsedUser, let host = _parsedHost {
      if hasAlias {
        result.append(NSAttributedString(
          string: " ",
          attributes: [.foregroundColor: _dimColor, .font: font]))
      }
      result.append(NSAttributedString(
        string: user,
        attributes: [.foregroundColor: userColor, .font: font]))
      if !aliasMatchesHost {
        result.append(NSAttributedString(
          string: "@",
          attributes: [.foregroundColor: _dimColor, .font: font]))
        result.append(NSAttributedString(
          string: host,
          attributes: [.foregroundColor: hostColor, .font: font]))
      }
    } else if let host = _parsedHost, !aliasMatchesHost {
      if hasAlias {
        result.append(NSAttributedString(
          string: " ",
          attributes: [.foregroundColor: _dimColor, .font: font]))
      }
      result.append(NSAttributedString(
        string: host,
        attributes: [.foregroundColor: hostColor, .font: font]))
    } else if !hasAlias {
      let fallback: String
      if let title = _rawTitle, !title.isEmpty {
        fallback = title
      } else {
        fallback = "blink"
      }
      result.append(NSAttributedString(
        string: fallback,
        attributes: [.foregroundColor: _cyanColor, .font: font]))
    }

    if let startTime = _sessionStartTime {
      result.append(NSAttributedString(
        string: " │ ",
        attributes: [.foregroundColor: _dimColor, .font: font]))
      result.append(NSAttributedString(
        string: "↑",
        attributes: [.foregroundColor: _dimColor, .font: font]))
      result.append(NSAttributedString(
        string: _formatUptime(since: startTime),
        attributes: [.foregroundColor: _amberColor, .font: font]))
    }

    return result
  }

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

  // MARK: - Timers

  private func _startClockTimer() {
    _clockTimer?.invalidate()
    _clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      self?._rebuildLabels()
    }
  }

  private func _startChipTimer() {
    _chipTimer?.invalidate()
    _chipTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      self?._refreshChips(animate: true)
    }
  }

  // MARK: - Pulse animation (status dot)

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

  // MARK: - Network monitor

  private func _startNetworkMonitor() {
    netMonitor.pathUpdateHandler = { [weak self] path in
      let str: String
      let sev: Int
      if path.status == .satisfied {
        if path.usesInterfaceType(.wifi) {
          str = "wifi"; sev = 0
        } else if path.usesInterfaceType(.cellular) {
          str = "cell"; sev = 0
        } else if path.usesInterfaceType(.wiredEthernet) {
          str = "eth"; sev = 0
        } else {
          str = "on"; sev = 0
        }
      } else {
        str = "off"; sev = 2
      }
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.netStatusString = str
        self.netStatusSeverity = sev
        self._refreshChips(animate: true)
      }
    }
    netMonitor.start(queue: DispatchQueue.global(qos: .background))
  }

  // MARK: - Status queries

  private func _readBattery() -> (String, Int) {
    let dev = UIDevice.current
    let level = dev.batteryLevel
    if level < 0 {
      return ("BAT --", 0)
    }
    let pct = Int(round(level * 100))
    let isCharging = (dev.batteryState == .charging || dev.batteryState == .full)
    let suffix = isCharging ? "↑" : ""
    let sev: Int
    if pct <= 10 { sev = 2 }
    else if pct <= 25 { sev = 1 }
    else { sev = 0 }
    return ("BAT \(pct)%\(suffix)", sev)
  }

  private func _readNetwork() -> (String, Int) {
    return ("NET \(netStatusString)", netStatusSeverity)
  }

  private func _readMemory() -> (String, Int) {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    guard kerr == KERN_SUCCESS else { return ("MEM --", 0) }
    let mb = Int(info.resident_size / (1024 * 1024))
    let sev: Int
    if mb >= 800 { sev = 2 }
    else if mb >= 500 { sev = 1 }
    else { sev = 0 }
    return ("MEM \(mb)M", sev)
  }

  private func _readThermal() -> (String, Int) {
    let s = ProcessInfo.processInfo.thermalState
    switch s {
    case .nominal:  return ("THM ok", 0)
    case .fair:     return ("THM warm", 0)
    case .serious:  return ("THM hot", 1)
    case .critical: return ("THM crit", 2)
    @unknown default: return ("THM ?", 0)
    }
  }

  private func _readSysUptime() -> (String, Int) {
    let elapsed = Int(ProcessInfo.processInfo.systemUptime)
    let d = elapsed / 86400
    let h = (elapsed % 86400) / 3600
    let m = (elapsed % 3600) / 60
    let str: String
    if d > 0 {
      str = "\(d)d\(h)h"
    } else if h > 0 {
      str = "\(h)h\(m)m"
    } else {
      str = "\(m)m"
    }
    let sev = ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0
    return ("SYS \(str)", sev)
  }

  private func _readDate() -> (String, Int) {
    return ("DAT \(_dateFormatter.string(from: Date()))", 0)
  }

  // MARK: - Chip refresh & animation

  private func _refreshChips(animate: Bool) {
    let readings: [(ChipKind, (String, Int))] = [
      (.battery,   _readBattery()),
      (.network,   _readNetwork()),
      (.memory,    _readMemory()),
      (.thermal,   _readThermal()),
      (.sysUptime, _readSysUptime()),
      (.date,      _readDate()),
    ]

    var widthDirty = false
    for (kind, (val, sev)) in readings {
      guard let label = chipLabels[kind] else { continue }
      let prevVal = chipValues[kind] ?? ""
      let prevSev = chipSeverity[kind] ?? 0
      let valueChanged = (prevVal != val)
      let sevChanged = (prevSev != sev)

      label.text = val
      label.textColor = _chipColor(kind, severity: sev)

      if valueChanged { widthDirty = true }

      if animate && (valueChanged || sevChanged) && !prevVal.isEmpty {
        _flashChip(label, severity: sev)
      }

      chipValues[kind] = val
      chipSeverity[kind] = sev
    }

    if widthDirty {
      setNeedsLayout()
    }
  }

  private func _flashChip(_ label: UILabel, severity: Int) {
    // Cross-fade old/new text rendering
    let trans = CATransition()
    trans.duration = 0.45
    trans.type = .fade
    label.layer.add(trans, forKey: "chipFade")

    // A scale bump scales severity differences too
    let scale: CGFloat = severity >= 2 ? 1.35 : (severity == 1 ? 1.25 : 1.18)
    label.layer.removeAnimation(forKey: "chipBump")
    let bump = CAKeyframeAnimation(keyPath: "transform.scale")
    bump.values = [1.0, scale, 1.0]
    bump.keyTimes = [0.0, 0.35, 1.0]
    bump.duration = 0.7
    bump.timingFunctions = [
      CAMediaTimingFunction(name: .easeOut),
      CAMediaTimingFunction(name: .easeInEaseOut),
    ]
    label.layer.add(bump, forKey: "chipBump")
  }

  private func _flashLabel(_ label: UILabel, scale: CGFloat) {
    label.layer.removeAnimation(forKey: "labelBump")
    let bump = CAKeyframeAnimation(keyPath: "transform.scale")
    bump.values = [1.0, scale, 1.0]
    bump.keyTimes = [0.0, 0.3, 1.0]
    bump.duration = 0.6
    bump.timingFunctions = [
      CAMediaTimingFunction(name: .easeOut),
      CAMediaTimingFunction(name: .easeInEaseOut),
    ]
    label.layer.add(bump, forKey: "labelBump")
  }

  private func _startChipBaselineAnimation() {
    // Subtle staggered breathing — keeps the row feeling alive without
    // the busy-ness of the old scan/drift HUD.
    let now = CACurrentMediaTime()
    for (i, kind) in ChipKind.allCases.enumerated() {
      guard let label = chipLabels[kind] else { continue }
      label.layer.removeAnimation(forKey: "breathe")
      let anim = CABasicAnimation(keyPath: "opacity")
      anim.fromValue = 0.78
      anim.toValue = 1.0
      anim.duration = 1.8 + Double(i) * 0.22
      anim.autoreverses = true
      anim.repeatCount = .infinity
      anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      anim.beginTime = now + Double(i) * 0.18
      anim.fillMode = .backwards
      label.layer.add(anim, forKey: "breathe")
    }
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

    let halfExclusion = centerExclusion / 2
    let midX = bounds.width / 2
    let labelHeight: CGFloat = 16
    let labelY = bounds.height - labelHeight - 7

    // Status dot — left edge, vertically centered with first-line labels
    let dotX = horizontalMargin
    let dotY = labelY + (labelHeight - dotSize) / 2
    statusDot.frame = CGRect(x: dotX, y: dotY, width: dotSize, height: dotSize)

    // First-line left
    let leftX = dotX + dotSize + 6
    let leftWidth = midX - halfExclusion - leftX
    leftLabel.frame = CGRect(
      x: leftX, y: labelY,
      width: max(leftWidth, 0), height: labelHeight)

    // First-line right
    let rightX = midX + halfExclusion
    let rightWidth = midX - halfExclusion - horizontalMargin
    rightLabel.frame = CGRect(
      x: rightX, y: labelY,
      width: max(rightWidth, 0), height: labelHeight)

    // Chip row — fills the area above first line, splitting around any
    // center exclusion (Dynamic Island / notch).
    let chipHeight: CGFloat = 14
    let chipY = labelY - chipHeight - 3

    if chipY < 2 {
      for (_, l) in chipLabels { l.isHidden = true }
      return
    }

    let allChips = ChipKind.allCases
    let half = allChips.count / 2
    let leftChips = Array(allChips.prefix(half))
    let rightChips = Array(allChips.suffix(allChips.count - half))

    let leftZoneStart = horizontalMargin
    let leftZoneEnd = midX - halfExclusion - 4
    let rightZoneStart = midX + halfExclusion + 4
    let rightZoneEnd = bounds.width - horizontalMargin

    _layoutChipRow(leftChips,
                   from: leftZoneStart, to: leftZoneEnd,
                   y: chipY, height: chipHeight)
    _layoutChipRow(rightChips,
                   from: rightZoneStart, to: rightZoneEnd,
                   y: chipY, height: chipHeight)
  }

  private func _layoutChipRow(
    _ chips: [ChipKind], from start: CGFloat, to end: CGFloat,
    y: CGFloat, height: CGFloat
  ) {
    let zoneWidth = end - start
    if zoneWidth < 30 {
      for kind in chips { chipLabels[kind]?.isHidden = true }
      return
    }

    let widths = chips.map { kind -> CGFloat in
      chipLabels[kind]?.intrinsicContentSize.width ?? 0
    }

    // Greedy fit from left: drop trailing chips that don't fit
    let minGap: CGFloat = 6
    var visibleCount = 0
    var totalUsed: CGFloat = 0
    for w in widths {
      let needed = totalUsed + w + (visibleCount > 0 ? minGap : 0)
      if needed > zoneWidth { break }
      totalUsed = needed
      visibleCount += 1
    }

    let extra = zoneWidth - totalUsed
    let gap: CGFloat = visibleCount > 1 ? minGap + extra / CGFloat(visibleCount - 1) : minGap

    var x = start
    for (i, kind) in chips.enumerated() {
      guard let label = chipLabels[kind] else { continue }
      if i < visibleCount {
        label.isHidden = false
        label.frame = CGRect(x: x, y: y, width: widths[i], height: height)
        x += widths[i] + gap
      } else {
        label.isHidden = true
      }
    }
  }
}
