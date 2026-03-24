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

class KBToolbarProfileManager {
  static let shared = KBToolbarProfileManager()

  private static let activeProfileKey = "KBToolbarActiveProfileId"

  private var _profilesURL: URL {
    BlinkPaths.blinkToolbarProfilesURL()
  }

  var activeProfileId: UUID? {
    get {
      guard let str = UserDefaults.standard.string(forKey: Self.activeProfileKey),
            let uuid = UUID(uuidString: str) else { return nil }
      return uuid
    }
    set {
      if let id = newValue {
        UserDefaults.standard.set(id.uuidString, forKey: Self.activeProfileKey)
      } else {
        UserDefaults.standard.removeObject(forKey: Self.activeProfileKey)
      }
    }
  }

  func setActiveProfile(id: UUID) {
    activeProfileId = id
  }

  func save(profile: KBToolbarProfile) {
    let fileURL = _profilesURL.appendingPathComponent("\(profile.id.uuidString).json")
    do {
      let data = try JSONEncoder().encode(profile)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      debugPrint("KBToolbarProfileManager: failed to save profile:", error)
    }
  }

  func loadAll() -> [KBToolbarProfile] {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(at: _profilesURL, includingPropertiesForKeys: nil) else {
      return []
    }
    return files
      .filter { $0.pathExtension == "json" }
      .compactMap { load(url: $0) }
      .sorted { $0.name < $1.name }
  }

  func load(id: UUID) -> KBToolbarProfile? {
    let fileURL = _profilesURL.appendingPathComponent("\(id.uuidString).json")
    return load(url: fileURL)
  }

  private func load(url: URL) -> KBToolbarProfile? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(KBToolbarProfile.self, from: data)
  }

  func delete(id: UUID) {
    let fileURL = _profilesURL.appendingPathComponent("\(id.uuidString).json")
    try? FileManager.default.removeItem(at: fileURL)
    if activeProfileId == id {
      activeProfileId = nil
    }
  }

  func activeProfile() -> KBToolbarProfile? {
    guard let id = activeProfileId else { return nil }
    return load(id: id)
  }

  func ensureDefaultProfile(for device: KBDevice, lang: String) {
    let profiles = loadAll()
    if profiles.isEmpty {
      let profile = KBToolbarProfile.defaultProfile(for: device, lang: lang)
      save(profile: profile)
      setActiveProfile(id: profile.id)
    }
  }
}
