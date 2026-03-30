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

class KBKeyViewSymbol: KBKeyView {
  var _imageView: UIImageView
  private var _textLabel: UILabel?

  override init(key: KBKey, keyDelegate: KBKeyViewDelegate) {
    _imageView = UIImageView(
      image: UIImage(
        systemName: key.shape.primaryValue.symbolName ?? "questionmark.diamond"
      )
    )

    super.init(key: key, keyDelegate: keyDelegate)

    isAccessibilityElement = true
    accessibilityValue = key.shape.primaryValue.accessibilityLabel
    accessibilityTraits.insert(UIAccessibilityTraits.keyboardKey)

    let kbSizes = keyDelegate.kbSizes

    if key.shape.primaryValue.symbolName == nil, case .text(let value) = key.shape.primaryValue {
      _imageView.isHidden = true
      let label = UILabel()
      label.text = value
      label.textAlignment = .center
      label.textColor = UIColor.label
      label.font = UIFont.systemFont(ofSize: kbSizes.key.fonts.symbol, weight: .medium)
      label.adjustsFontSizeToFitWidth = true
      label.minimumScaleFactor = 0.5
      addSubview(label)
      _textLabel = label
    } else {
      _imageView.contentMode = .center
      _imageView.preferredSymbolConfiguration = .init(pointSize: kbSizes.key.fonts.symbol,
                                                      weight: .regular)
      _imageView.tintColor = UIColor.label
      addSubview(_imageView)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let insets = keyDelegate.kbSizes.key.insets.symbol
    _imageView.frame = bounds.inset(by: insets)
    _textLabel?.frame = bounds.inset(by: insets)
  }
  
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesBegan(touches, with: event)
    if key.isModifier {
      self.backgroundColor = .white
      _imageView.tintColor = UIColor.darkText
    }
  }
  
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard
       let touch = trackingTouch,
       touches.contains(touch)
     else {
       super.touchesEnded(touches, with: event)
       return
     }
    
    guard
      keyDelegate.keyViewCanGoOff(keyView: self, value: key.shape.primaryValue)
    else {
      return
    }
    
    if !shouldAutoRepeat {
      keyDelegate.keyViewTriggered(keyView: self, value: key.shape.primaryValue)
    }
    super.touchesEnded(touches, with: event)
  }
  
  override var shouldAutoRepeat: Bool {
    switch key.shape.primaryValue {
    case .esc, .left, .right, .up, .down, .tab, .return:
      return true
    default: return super.shouldAutoRepeat
    }
  }
  
  override func turnOff() {
    super.turnOff()
    _imageView.tintColor = UIColor.label
    if key.shape.primaryValue.isModifier {
      accessibilityTraits.remove([.selected])
    }
  }
  
  override func turnOn() {
    super.turnOn()
    if key.shape.primaryValue.isModifier {
      accessibilityTraits.insert([.selected])
    }
  }

  func updateIcon(systemName: String) {
    _imageView.image = UIImage(systemName: systemName)
  }

}
