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

import Foundation

struct KBToolbarProfile: Codable, Identifiable {
  let id: UUID
  var name: String
  var middleKeys: [KBKey]
  var leftKeys: [KBKey]?    // nil = use device default
  var rightKeys: [KBKey]?   // nil = use device default

  static func defaultProfile(for device: KBDevice, lang: String) -> Self {
    let layout = device.layoutFor(lang: lang)
    return Self(id: UUID(), name: "Default",
                middleKeys: layout.middle.normalizedForProfile(),
                leftKeys: layout.left.normalizedForProfile(),
                rightKeys: layout.right.normalizedForProfile())
  }
}

extension Array where Element == KBKey {
  func normalizedForProfile() -> [KBKey] {
    let representative = KBTraits.initial
      .union(.portrait)
      .subtracting(.landscape)

    var seen = Set<String>()
    var result: [KBKey] = []

    for key in self where key.match(traits: representative) {
      let logicalId: String
      if case .arrows = key.shape {
        logicalId = "arrows"
      } else {
        logicalId = key.shape.primaryValue.id
      }
      if seen.insert(logicalId).inserted {
        result.append(KBKey(key.shape, traits: .all))
      }
    }
    return result
  }
}
