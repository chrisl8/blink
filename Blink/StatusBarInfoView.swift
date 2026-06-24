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

  // MARK: - Info-grid views
  //
  // The Dynamic Island sits in the dead center. Usable regions (measured on
  // iPhone 16 Pro Max — see _layoutDebugRuler notes):
  //   • Status band: 62pt tall, full width, drawable from y=0.
  //   • Island pill: x≈165–282 (≈125pt, centered on 220), y≈13–53.
  //   • Above-Island strip (y0–12): clear in the CENTER only; far corners are
  //     clipped by the rounded screen — keep content centered there.
  //   • Two side columns (x16–150 / x290–424) are clear of the pill at any y.
  //   • Bottom ~7pt is shared with scrolled terminal text (tested-OK margin).
  //
  // Layout:
  //                ≡alias  user@host                 hostLine (above Island)
  //   ● ▸1/2 │ clock   ▕ISLAND▏   BAT  NET           left col / right col chips
  //     ↑uptime        ▕ISLAND▏   THM→SYS→DAT→DSK     left col / right col rot.
  //
  // Left column = blink/session, right column = phone chips, host spans the
  // full-width strip above the Island.

  private let hostLine = UILabel()       // above Island, centered (alias + host)
  private let leftLabel = UILabel()      // left col, top row: window + clock
  private let botLeftLabel = UILabel()   // left col, bottom row: session uptime
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

  // Live network throughput (device-wide, from OS interface counters — works
  // regardless of mosh/ssh/local). Rates are bytes/sec.
  private var _prevRxCounter: UInt64 = 0
  private var _prevTxCounter: UInt64 = 0
  private var _prevNetSampleTime: Date?
  private var _rxRate: Double = 0
  private var _txRate: Double = 0
  // Rolling history for the host-flank activity bars (oldest…newest).
  private var _rxHistory: [Double] = []
  private var _txHistory: [Double] = []
  private let _historyCap = 48
  private let rxBars = ThroughputBarsView()   // left of host (download)
  private let txBars = ThroughputBarsView()   // right of host (upload)
  private var _pulseDuration: Double = 1.8

  // First-line change tracking (for animations)
  private var _prevWindowIndex: Int = -1
  private var _prevWindowCount: Int = -1
  private var _prevHostDisplay: String = ""
  private var _prevMinute: Int = -1

  // MARK: - Status chips

  private enum ChipKind: Int, CaseIterable {
    case battery, network, thermal, sysUptime, date, diskFree
  }

  // Always-visible chips (left zone) vs. the slowly-cycling set (right zone).
  private let _fixedKinds: [ChipKind] = [.battery, .network]
  private let _rotatingKinds: [ChipKind] = [.thermal, .sysUptime, .diskFree]

  private var chipLabels: [ChipKind: UILabel] = [:]
  private var chipValues: [ChipKind: String] = [:]
  private var chipSeverity: [ChipKind: Int] = [:]

  // Rotation state for the right-zone slot
  private var _rotationTimer: Timer?
  private var _rotationIndex: Int = 0
  private var _rotationPinned: Bool = false  // held on a critical reading
  private let _rotationInterval: TimeInterval = 5.0

  // TEMPORARY: calibration overlay to map the visible region vs. the Dynamic
  // Island in a screenshot. Flip to false (or delete this block + the method
  // + the early-return in layoutSubviews) once the real layout is dialed in.
  private let _debugLayout = false
  private var _debugViews: [UIView] = []

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

    // Host line sits above the Island, centered, slightly smaller to fit the
    // ~12pt strip. Truncates the head so the host (tail) stays readable.
    hostLine.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .medium)
    hostLine.textAlignment = .center
    hostLine.lineBreakMode = .byTruncatingHead

    // Left column hugs the Island (right-aligned) so its content sits beside
    // the pill rather than stranded at the screen edge.
    leftLabel.font = font
    leftLabel.textAlignment = .right
    leftLabel.lineBreakMode = .byTruncatingTail

    botLeftLabel.font = font
    botLeftLabel.textAlignment = .right
    botLeftLabel.lineBreakMode = .byTruncatingTail

    statusDot.layer.cornerRadius = dotSize / 2
    statusDot.backgroundColor = UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0)

    // Activity bars that flank the host line (download left, upload right),
    // coloured from an 80s synth palette with offset seeds so the two sides differ.
    rxBars.seed = 0
    txBars.seed = 2
    rxBars.newestInnerEdge = .right  // newest bar nearest the host (its right edge)
    txBars.newestInnerEdge = .left   // newest bar nearest the host (its left edge)

    addSubview(statusDot)
    addSubview(rxBars)
    addSubview(txBars)
    addSubview(hostLine)
    addSubview(leftLabel)
    addSubview(botLeftLabel)

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
    _rotationTimer?.invalidate()
    netMonitor.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  override func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)
    if newSuperview != nil {
      _resetThroughputBaseline()
      _startClockTimer()
      _startChipTimer()
      _startRotationTimer()
      _startPulseAnimation()
      _refreshChips(animate: false)
      _startChipBaselineAnimation()
    } else {
      _clockTimer?.invalidate(); _clockTimer = nil
      _chipTimer?.invalidate(); _chipTimer = nil
      _rotationTimer?.invalidate(); _rotationTimer = nil
    }
  }

  @objc private func _appWillEnterForeground() {
    _resetThroughputBaseline()
    _startClockTimer()
    _startChipTimer()
    _startRotationTimer()
    _startPulseAnimation()
    _refreshChips(animate: false)
    _startChipBaselineAnimation()
    _rebuildLabels()
  }

  @objc private func _appDidEnterBackground() {
    _clockTimer?.invalidate(); _clockTimer = nil
    _chipTimer?.invalidate(); _chipTimer = nil
    _rotationTimer?.invalidate(); _rotationTimer = nil
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
    case .diskFree:
      return _isLightBg
        ? UIColor(red: 0.2, green: 0.45, blue: 0.5, alpha: 0.85)
        : UIColor(red: 0.55, green: 0.9, blue: 0.9, alpha: 0.78)
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
    _sampleThroughput()
    let now = Date()
    let cal = Calendar.current
    let curMinute = cal.component(.minute, from: now)
    let minuteTicked = (_prevMinute != curMinute && _prevMinute != -1)
    _prevMinute = curMinute

    leftLabel.attributedText = _buildLeftAttributedString(now: now)
    botLeftLabel.attributedText = _buildBottomLeftString()
    hostLine.attributedText = _buildHostLineString()

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
      _flashLabel(hostLine, scale: 1.18)
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
        string: "▸",
        attributes: [.foregroundColor: _dimColor, .font: font]))
      result.append(NSAttributedString(
        string: "\(_windowIndex)/\(_windowCount) ",
        attributes: [.foregroundColor: _amberColor, .font: font]))
    }

    let timeStr = _clockFormatter.string(from: now)
    result.append(NSAttributedString(
      string: timeStr,
      attributes: [.foregroundColor: _greenColor, .font: font]))

    if let startTime = _sessionStartTime {
      result.append(NSAttributedString(
        string: " ↑",
        attributes: [.foregroundColor: _dimColor, .font: font]))
      result.append(NSAttributedString(
        string: _formatUptime(since: startTime),
        attributes: [.foregroundColor: _amberColor, .font: font]))
    }

    return result
  }

  /// The full-width line above the Island: "≡alias  user@host". Smaller font
  /// to fit the ~12pt strip; centered so it stays clear of the corner curves.
  private func _buildHostLineString() -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = UIFont.monospacedSystemFont(ofSize: 9, weight: .medium)

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

    if let user = _parsedUser, let host = _parsedHost {
      if hasAlias {
        result.append(NSAttributedString(
          string: "  ", attributes: [.font: font]))
      }
      result.append(NSAttributedString(
        string: user,
        attributes: [.foregroundColor: _purpleColor, .font: font]))
      if !aliasMatchesHost {
        result.append(NSAttributedString(
          string: "@",
          attributes: [.foregroundColor: _dimColor, .font: font]))
        result.append(NSAttributedString(
          string: host,
          attributes: [.foregroundColor: _cyanColor, .font: font]))
      }
    } else if let host = _parsedHost, !aliasMatchesHost {
      if hasAlias {
        result.append(NSAttributedString(
          string: "  ", attributes: [.font: font]))
      }
      result.append(NSAttributedString(
        string: host,
        attributes: [.foregroundColor: _cyanColor, .font: font]))
    } else if !hasAlias {
      let fallback = (_rawTitle?.isEmpty == false) ? _rawTitle! : "blink"
      result.append(NSAttributedString(
        string: fallback,
        attributes: [.foregroundColor: _cyanColor, .font: font]))
    }

    return result
  }

  /// Left column, bottom row: date + live network throughput
  /// ("06/23 ▼1.2M ▲45K"). Throughput is device-wide bytes/sec (works for mosh,
  /// ssh, anything) so you can spot the link "chugging" while idle.
  private func _buildBottomLeftString() -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)

    result.append(NSAttributedString(
      string: _dateFormatter.string(from: Date()),
      attributes: [.foregroundColor: _primaryColor, .font: font]))

    result.append(NSAttributedString(
      string: "  ▼",
      attributes: [.foregroundColor: _dimColor, .font: font]))
    result.append(NSAttributedString(
      string: _formatRate(_rxRate),
      attributes: [.foregroundColor: _cyanColor, .font: font]))
    result.append(NSAttributedString(
      string: " ▲",
      attributes: [.foregroundColor: _dimColor, .font: font]))
    result.append(NSAttributedString(
      string: _formatRate(_txRate),
      attributes: [.foregroundColor: _greenColor, .font: font]))

    return result
  }

  /// Compact per-second rate: 0B / 1.2K / 45K / 1.2M / 12M.
  private func _formatRate(_ bytesPerSec: Double) -> String {
    let bps = max(bytesPerSec, 0)
    if bps < 1024 { return "\(Int(bps))B" }
    if bps < 1024 * 1024 {
      let k = bps / 1024
      return k < 10 ? String(format: "%.1fK", k) : "\(Int(k))K"
    }
    let m = bps / (1024 * 1024)
    return m < 10 ? String(format: "%.1fM", m) : "\(Int(m))M"
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
    anim.duration = _pulseDuration
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
        self._updateDot()
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

  private func _readDiskFree() -> (String, Int) {
    let url = URL(fileURLWithPath: NSHomeDirectory())
    guard let vals = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
          let bytes = vals.volumeAvailableCapacityForImportantUsage else {
      return ("DSK --", 0)
    }
    let gb = Double(bytes) / 1_000_000_000.0
    let str: String
    if gb >= 100 { str = "\(Int(gb))G" }
    else if gb >= 10 { str = "\(Int(gb))G" }
    else { str = String(format: "%.1fG", gb) }
    let sev = gb < 2 ? 1 : 0
    return ("DSK \(str)", sev)
  }

  // MARK: - Network throughput

  /// Sum cumulative byte counters across the physical interfaces (WiFi `en*`,
  /// cellular `pdp_ip*`) from the OS. This is below mosh/ssh, so it captures
  /// all session traffic regardless of protocol.
  private func _readNetCounters() -> (rx: UInt64, tx: UInt64) {
    var rx: UInt64 = 0, tx: UInt64 = 0
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0 else { return (0, 0) }
    defer { freeifaddrs(ifaddrPtr) }

    var ptr = ifaddrPtr
    while let cur = ptr {
      let ifa = cur.pointee
      if let cName = ifa.ifa_name,
         let name = String(validatingUTF8: cName),
         name.hasPrefix("en") || name.hasPrefix("pdp_ip"),
         let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
         let dataPtr = ifa.ifa_data {
        let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
        rx += UInt64(data.ifi_ibytes)
        tx += UInt64(data.ifi_obytes)
      }
      ptr = ifa.ifa_next
    }
    return (rx, tx)
  }

  /// Re-baseline so the first sample after (re)appearing doesn't average a
  /// long background gap into a bogus rate.
  private func _resetThroughputBaseline() {
    _prevNetSampleTime = nil
  }

  private func _sampleThroughput() {
    let now = Date()
    let (rx, tx) = _readNetCounters()
    guard let prev = _prevNetSampleTime else {
      _prevRxCounter = rx; _prevTxCounter = tx; _prevNetSampleTime = now
      return
    }
    let elapsed = now.timeIntervalSince(prev)
    guard elapsed >= 1.0 else { return }  // smooth: ignore sub-second resamples
    // 32-bit counters can wrap; treat a decrease as 0 for that interval.
    let dRx = rx >= _prevRxCounter ? Double(rx - _prevRxCounter) : 0
    let dTx = tx >= _prevTxCounter ? Double(tx - _prevTxCounter) : 0
    _rxRate = dRx / elapsed
    _txRate = dTx / elapsed
    _prevRxCounter = rx; _prevTxCounter = tx; _prevNetSampleTime = now

    _rxHistory.append(_rxRate); _txHistory.append(_txRate)
    if _rxHistory.count > _historyCap { _rxHistory.removeFirst() }
    if _txHistory.count > _historyCap { _txHistory.removeFirst() }
    rxBars.setSamples(_rxHistory)
    txBars.setSamples(_txHistory)
    _updateDot()
  }

  /// Dot color = network reachability (green up / red down); pulse speed scales
  /// with live throughput so it calms when idle and races when the link is busy.
  private func _updateDot() {
    let down = netStatusSeverity >= 2
    statusDot.backgroundColor = down
      ? UIColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1.0)
      : UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0)

    let total = _rxRate + _txRate
    let dur: Double
    if total < 2048 {
      dur = 1.8
    } else {
      let f = min(total / (512 * 1024), 1.0)  // 512 KB/s → fastest
      dur = 1.8 - 1.4 * f
    }
    if abs(dur - _pulseDuration) > 0.06 {
      _pulseDuration = dur
      _startPulseAnimation()
    }
  }

  // MARK: - Chip refresh & animation

  private func _refreshChips(animate: Bool) {


    let readings: [(ChipKind, (String, Int))] = [
      (.battery,   _readBattery()),
      (.network,   _readNetwork()),
      (.thermal,   _readThermal()),
      (.sysUptime, _readSysUptime()),
      (.date,      _readDate()),
      (.diskFree,  _readDiskFree()),
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

      // Only flash chips the user can actually see (hidden rotating slots
      // surface via the fade transition when they next come around).
      if animate && (valueChanged || sevChanged) && !prevVal.isEmpty && !label.isHidden {
        _flashChip(label, severity: sev)
      }

      chipValues[kind] = val
      chipSeverity[kind] = sev
    }

    if _applyRotationPinning() { widthDirty = true }

    if widthDirty {
      setNeedsLayout()
    }
  }

  /// If a rotating reading is critical (severity ≥ 2), pin the slot to it so a
  /// real warning can't be hidden behind the cycle. Returns true if the visible
  /// rotating kind changed as a result.
  private func _applyRotationPinning() -> Bool {
    let sevs = _rotatingKinds.map { chipSeverity[$0] ?? 0 }
    guard let maxSev = sevs.max() else { _rotationPinned = false; return false }
    if maxSev >= 2, let idx = sevs.firstIndex(of: maxSev) {
      _rotationPinned = true
      if idx != _rotationIndex {
        _rotationIndex = idx
        _applyRotationTransition()
        return true
      }
      return false
    }
    _rotationPinned = false
    return false
  }

  // MARK: - Rotation

  private func _startRotationTimer() {
    _rotationTimer?.invalidate()
    _rotationTimer = Timer.scheduledTimer(
      withTimeInterval: _rotationInterval, repeats: true) { [weak self] _ in
      self?._advanceRotation()
    }
  }

  private func _advanceRotation() {
    guard _rotatingKinds.count > 1, !_rotationPinned else { return }
    _rotationIndex = (_rotationIndex + 1) % _rotatingKinds.count
    _applyRotationTransition()
    setNeedsLayout()
    layoutIfNeeded()
  }

  /// Cross-fade the right-zone slot as the visible kind swaps.
  private func _applyRotationTransition() {
    for kind in _rotatingKinds {
      guard let label = chipLabels[kind] else { continue }
      let t = CATransition()
      t.duration = 0.5
      t.type = .fade
      label.layer.add(t, forKey: "rotateFade")
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
    // Only the always-visible chips breathe; rotating slots toggle visibility
    // via opacity, so a repeating opacity animation there would fight the fade.
    let now = CACurrentMediaTime()
    for (i, kind) in _fixedKinds.enumerated() {
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

  // MARK: - Debug calibration overlay (TEMPORARY)

  /// Fills the entire view region with a coordinate grid so a screenshot
  /// reveals exactly which pixels are visible vs. occluded by the Dynamic
  /// Island and the rounded screen corners. The Island renders as an opaque
  /// black pill over this grid — read its edges off the rulers.
  private func _layoutDebugRuler() {
    _debugViews.forEach { $0.removeFromSuperview() }
    _debugViews.removeAll()

    // Hide all normal content while testing.
    hostLine.isHidden = true
    leftLabel.isHidden = true
    botLeftLabel.isHidden = true
    statusDot.isHidden = true
    rxBars.isHidden = true
    txBars.isHidden = true
    for (_, l) in chipLabels { l.isHidden = true }

    let w = bounds.width
    let h = bounds.height

    func add(_ v: UIView) { addSubview(v); _debugViews.append(v) }

    // Full-bleed translucent fill: shows how far into the corners we can draw.
    let bg = UIView(frame: bounds)
    bg.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.20)
    add(bg)

    let font = UIFont.monospacedSystemFont(ofSize: 7, weight: .bold)

    // Horizontal rules + y markers (left / center / right) every 6px.
    var y: CGFloat = 0
    while y <= h {
      let line = UIView(frame: CGRect(x: 0, y: y, width: w, height: 0.5))
      line.backgroundColor = UIColor.white.withAlphaComponent(0.30)
      add(line)

      let positions: [(NSTextAlignment, CGFloat)] = [
        (.left, 1), (.center, w / 2 - 16), (.right, w - 33),
      ]
      for (align, x) in positions {
        let lbl = UILabel(frame: CGRect(x: x, y: y - 4, width: 32, height: 8))
        lbl.font = font
        lbl.textColor = .white
        lbl.textAlignment = align
        lbl.text = "y\(Int(y))"
        add(lbl)
      }
      y += 6
    }

    // Vertical ticks + x markers every 30px along the bottom edge.
    var x: CGFloat = 0
    while x <= w {
      let tick = UIView(frame: CGRect(x: x, y: 0, width: 0.5, height: h))
      tick.backgroundColor = UIColor.white.withAlphaComponent(0.18)
      add(tick)

      let lbl = UILabel(frame: CGRect(x: x + 1, y: h - 9, width: 28, height: 8))
      lbl.font = font
      lbl.textColor = .yellow
      lbl.text = "\(Int(x))"
      add(lbl)
      x += 30
    }

    // Real sample chip text at the very top row — does it read beside/over
    // the Island?
    let sampleFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)
    let topLeft = UILabel(frame: CGRect(x: 4, y: 0, width: w / 2 - 4, height: 13))
    topLeft.font = sampleFont
    topLeft.textColor = .green
    topLeft.text = "BAT 88%↑ NET wifi"
    add(topLeft)

    let topRight = UILabel(frame: CGRect(x: w / 2, y: 0, width: w / 2 - 4, height: 13))
    topRight.font = sampleFont
    topRight.textColor = .green
    topRight.textAlignment = .right
    topRight.text = "THM ok SYS 23d20h"
    add(topRight)
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()

    if _debugLayout {
      _layoutDebugRuler()
      return
    }

    let device = DeviceInfo.shared()
    // Width of the dead center to keep clear. For the Island this is wider than
    // the pill (≈125pt) so text never tucks under its rounded ends.
    let centerExclusion: CGFloat
    if device.hasDynamicIsland {
      centerExclusion = 150
    } else if device.hasNotch {
      centerExclusion = 215
    } else {
      centerExclusion = 0
    }

    let halfExclusion = centerExclusion / 2
    let midX = bounds.width / 2

    // Two stacked rows in the side columns. Bottom row keeps its long-tested
    // 7pt margin; the top row stacks just above it.
    let rowHeight: CGFloat = 15
    let bottomRowY = bounds.height - rowHeight - 7
    let topRowY = bottomRowY - rowHeight - 2

    let leftZoneStart = horizontalMargin
    let leftZoneEnd = midX - halfExclusion - 4
    let rightZoneStart = midX + halfExclusion + 4
    let rightZoneEnd = bounds.width - horizontalMargin

    // Host line: full-width strip above the Island, centered. Inset from the
    // far corners (rounded-corner clipping) and kept above the pill (y≈13).
    hostLine.isHidden = false
    hostLine.frame = CGRect(x: 40, y: 0, width: max(bounds.width - 80, 0), height: 12)

    // Throughput activity bars flank the centered host text. Place them in the
    // gaps the title leaves; hide a side if its gap is too small.
    let stripInset: CGFloat = 34   // clear of the rounded top corners
    let textW = min(hostLine.intrinsicContentSize.width, hostLine.bounds.width)
    let textLeft = hostLine.frame.midX - textW / 2
    let textRight = hostLine.frame.midX + textW / 2
    let barGap: CGFloat = 6
    let barsY: CGFloat = 1, barsH: CGFloat = 10
    let minBarsW: CGFloat = 16

    let leftBarsW = (textLeft - barGap) - stripInset
    if leftBarsW >= minBarsW {
      rxBars.isHidden = false
      rxBars.frame = CGRect(x: stripInset, y: barsY, width: leftBarsW, height: barsH)
    } else {
      rxBars.isHidden = true
    }

    let rightBarsStart = textRight + barGap
    let rightBarsW = (bounds.width - stripInset) - rightBarsStart
    if rightBarsW >= minBarsW {
      txBars.isHidden = false
      txBars.frame = CGRect(x: rightBarsStart, y: barsY, width: rightBarsW, height: barsH)
    } else {
      txBars.isHidden = true
    }

    // Left column: both rows right-aligned to the Island edge. Top = window +
    // clock, bottom = date + uptime.
    let leftColWidth = max(leftZoneEnd - leftZoneStart, 0)
    leftLabel.frame = CGRect(
      x: leftZoneStart, y: topRowY, width: leftColWidth, height: rowHeight)
    botLeftLabel.frame = CGRect(
      x: leftZoneStart, y: bottomRowY, width: leftColWidth, height: rowHeight)

    // Activity dot rides just left of the (right-aligned) clock text.
    let topTextW = min(leftLabel.intrinsicContentSize.width, leftColWidth)
    let dotX = max(leftZoneEnd - topTextW - dotSize - 5, leftZoneStart)
    statusDot.isHidden = false
    statusDot.frame = CGRect(
      x: dotX, y: topRowY + (rowHeight - dotSize) / 2,
      width: dotSize, height: dotSize)

    // Right column (phone): fixed chips on top, two staggered rotating metrics
    // spread across the bottom (matches the top row's fullness, more dynamic).
    if rightZoneEnd - rightZoneStart >= 30 {
      _layoutChipRow(_fixedKinds,
                     from: rightZoneStart, to: rightZoneEnd,
                     y: topRowY, height: rowHeight, justified: false)
      _layoutRotatingPair(from: rightZoneStart, to: rightZoneEnd,
                          y: bottomRowY, height: rowHeight)
    } else {
      for (_, l) in chipLabels { l.isHidden = true }
    }
  }

  /// Shows two consecutive rotating metrics at once, spread across the zone,
  /// cycling so each metric slides through over time.
  private func _layoutRotatingPair(
    from start: CGFloat, to end: CGFloat, y: CGFloat, height: CGFloat
  ) {
    let n = _rotatingKinds.count
    guard n > 0 else { return }
    let i = _rotationIndex % n
    var visible = [_rotatingKinds[i]]
    if n > 1 { visible.append(_rotatingKinds[(i + 1) % n]) }

    for kind in _rotatingKinds where !visible.contains(kind) {
      chipLabels[kind]?.isHidden = true
    }
    _layoutChipRow(visible, from: start, to: end, y: y, height: height)
  }

  /// Lays out chips left-to-right in a zone, dropping any that don't fit.
  /// - justified: spread to fill the zone edge-to-edge (extra space → gaps).
  ///   When false, chips pack with a fixed gap and the group is centered, so
  ///   short chips sit together instead of being flung to the zone edges.
  private func _layoutChipRow(
    _ chips: [ChipKind], from start: CGFloat, to end: CGFloat,
    y: CGFloat, height: CGFloat, justified: Bool = true
  ) {
    let zoneWidth = end - start
    if zoneWidth < 30 {
      for kind in chips { chipLabels[kind]?.isHidden = true }
      return
    }

    let widths = chips.map { kind -> CGFloat in
      chipLabels[kind]?.intrinsicContentSize.width ?? 0
    }

    let minGap: CGFloat = justified ? 6 : 14

    // Greedy fit from left: drop trailing chips that don't fit
    var visibleCount = 0
    var totalUsed: CGFloat = 0
    for w in widths {
      let needed = totalUsed + w + (visibleCount > 0 ? minGap : 0)
      if needed > zoneWidth { break }
      totalUsed = needed
      visibleCount += 1
    }

    let gap: CGFloat
    var x = start
    if justified {
      let extra = zoneWidth - totalUsed
      gap = visibleCount > 1 ? minGap + extra / CGFloat(visibleCount - 1) : minGap
    } else {
      gap = minGap
      x = start + (zoneWidth - totalUsed) / 2  // center the packed group
    }

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

/// Tiny activity bars driven by a rolling history of values (oldest…newest).
/// Auto-scales (sqrt against a rolling peak with a floor) so both faint and
/// heavy traffic register. The newest sample is drawn nearest the inner edge
/// (toward the host line) so activity appears to emanate from the title.
private final class ThroughputBarsView: UIView {
  enum InnerEdge { case left, right }

  // 80s synth palette — no blue/green (those are used elsewhere in the bar).
  private static let synthPalette: [UIColor] = [
    UIColor(red: 1.00, green: 0.18, blue: 0.62, alpha: 0.9), // hot pink
    UIColor(red: 0.85, green: 0.15, blue: 0.95, alpha: 0.9), // magenta
    UIColor(red: 0.58, green: 0.22, blue: 1.00, alpha: 0.9), // electric purple
    UIColor(red: 1.00, green: 0.45, blue: 0.10, alpha: 0.9), // sunset orange
    UIColor(red: 1.00, green: 0.28, blue: 0.40, alpha: 0.9), // neon coral
  ]

  private var samples: [Double] = []
  private var phase = 0
  /// Per-view offset so the left/right flanks don't mirror identical colors.
  var seed: Int = 0
  var newestInnerEdge: InnerEdge = .right

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isUserInteractionEnabled = false
    isOpaque = false
    contentMode = .redraw
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func setSamples(_ s: [Double]) {
    samples = s
    phase += 1            // gentle palette drift between samples (≈ every 4s)
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    guard !samples.isEmpty, let ctx = UIGraphicsGetCurrentContext() else { return }

    let barW: CGFloat = 2, gap: CGFloat = 1
    let unit = barW + gap
    let capacity = max(Int(rect.width / unit), 1)
    let shown = Array(samples.suffix(capacity))

    // Rolling peak with an ~8 KB/s floor: idle stays a flat low line, bursts grow.
    let peak = max(shown.max() ?? 1, 8192)
    let palette = Self.synthPalette
    let drift = phase / 4   // slow the hue shimmer down

    // Draw by slot (0 = inner edge nearest the host) so the colour pattern is
    // anchored to the view and bars rise/fall within it.
    for slot in 0..<shown.count {
      let v = shown[shown.count - 1 - slot]   // newest at the inner edge
      let frac = CGFloat((max(v, 0) / peak).squareRoot())
      let h = max(rect.height * min(frac, 1.0), 0.5)
      let x = (newestInnerEdge == .right)
        ? rect.width - CGFloat(slot + 1) * unit
        : CGFloat(slot) * unit
      // Scattered-but-stable palette index, nudged by the slow drift.
      let ci = (slot * 7 + seed + drift) % palette.count
      ctx.setFillColor(palette[ci].cgColor)
      ctx.fill(CGRect(x: x, y: rect.height - h, width: barW, height: h))
    }
  }
}
