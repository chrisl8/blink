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

import SwiftUI

struct KBToolbarProfilesView: View {
  @State private var profiles: [KBToolbarProfile] = []
  @State private var activeId: UUID? = nil

  private let manager = KBToolbarProfileManager.shared

  var body: some View {
    List {
      Section("Profiles") {
        ForEach(profiles) { profile in
          HStack {
            Text(profile.name)
            Spacer()
            if profile.id == activeId {
              Image(systemName: "checkmark")
                .foregroundColor(.accentColor)
            }
          }
          .contentShape(Rectangle())
          .onTapGesture {
            activeId = profile.id
            manager.setActiveProfile(id: profile.id)
          }
        }
        .onDelete(perform: deleteProfiles)
      }

      Section {
        NavigationLink("Create New Profile") {
          KBToolbarProfileEditView(
            profile: nil,
            onSave: { reload() }
          )
        }
      }

      if let active = profiles.first(where: { $0.id == activeId }) {
        Section {
          NavigationLink("Edit \"\(active.name)\"") {
            KBToolbarProfileEditView(
              profile: active,
              onSave: { reload() }
            )
          }
        }
      }
    }
    .listStyle(.grouped)
    .navigationTitle("Toolbar Profiles")
    .onAppear { reload() }
  }

  private func reload() {
    profiles = manager.loadAll()
    activeId = manager.activeProfileId
    if activeId == nil, let first = profiles.first {
      activeId = first.id
      manager.setActiveProfile(id: first.id)
    }
  }

  private func deleteProfiles(at offsets: IndexSet) {
    guard profiles.count - offsets.count >= 1 else { return }
    for index in offsets {
      manager.delete(id: profiles[index].id)
    }
    reload()
  }
}

// MARK: - Profile Edit View

struct KBToolbarProfileEditView: View {
  let profile: KBToolbarProfile?
  let onSave: () -> Void

  @State private var name: String = ""
  @State private var leftKeys: [KBKey] = []
  @State private var middleKeys: [KBKey] = []
  @State private var rightKeys: [KBKey] = []
  @Environment(\.dismiss) private var dismiss

  private let manager = KBToolbarProfileManager.shared

  var body: some View {
    List {
      Section("Name") {
        TextField("Profile Name", text: $name)
      }

      // MARK: Left Section
      Section("Left Section Keys") {
        ForEach(Array(leftKeys.enumerated()), id: \.offset) { _, key in
          Text(displayText(for: key))
        }
        .onDelete { leftKeys.remove(atOffsets: $0) }
        .onMove { leftKeys.move(fromOffsets: $0, toOffset: $1) }
      }

      Section("Add Left Keys") {
        ForEach(sideAvailableKeys, id: \.id) { key in
          Button(action: { leftKeys.append(key) }) {
            HStack {
              Text(displayText(for: key))
              Spacer()
              Image(systemName: "plus.circle")
                .foregroundColor(.accentColor)
            }
          }
        }
      }

      // MARK: Middle Section
      Section("Middle Section Keys") {
        ForEach(Array(middleKeys.enumerated()), id: \.offset) { _, key in
          Text(displayText(for: key))
        }
        .onDelete { middleKeys.remove(atOffsets: $0) }
        .onMove { middleKeys.move(fromOffsets: $0, toOffset: $1) }
      }

      Section("Add Middle Keys") {
        ForEach(middleAvailableKeys, id: \.id) { key in
          Button(action: { middleKeys.append(key) }) {
            HStack {
              Text(displayText(for: key))
              Spacer()
              Image(systemName: "plus.circle")
                .foregroundColor(.accentColor)
            }
          }
        }
      }

      // MARK: Right Section
      Section("Right Section Keys") {
        ForEach(Array(rightKeys.enumerated()), id: \.offset) { _, key in
          Text(displayText(for: key))
        }
        .onDelete { rightKeys.remove(atOffsets: $0) }
        .onMove { rightKeys.move(fromOffsets: $0, toOffset: $1) }
      }

      Section("Add Right Keys") {
        ForEach(sideAvailableKeys, id: \.id) { key in
          Button(action: { rightKeys.append(key) }) {
            HStack {
              Text(displayText(for: key))
              Spacer()
              Image(systemName: "plus.circle")
                .foregroundColor(.accentColor)
            }
          }
        }
      }

      // MARK: Reset
      Section {
        Button("Reset to Defaults") {
          let device = KBDevice.detect()
          let layout = device.layoutFor(lang: "")
          leftKeys = layout.left.normalizedForProfile()
          middleKeys = layout.middle.normalizedForProfile()
          rightKeys = layout.right.normalizedForProfile()
        }
        .foregroundColor(.red)
      }
    }
    .listStyle(.grouped)
    .navigationTitle(profile == nil ? "New Profile" : "Edit Profile")
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        Button("Save") { saveProfile() }
          .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        EditButton()
      }
    }
    .onAppear {
      let device = KBDevice.detect()
      let layout = device.layoutFor(lang: "")
      if let p = profile {
        name = p.name
        leftKeys = p.leftKeys ?? layout.left.normalizedForProfile()
        middleKeys = p.middleKeys
        rightKeys = p.rightKeys ?? layout.right.normalizedForProfile()
      } else {
        name = ""
        leftKeys = layout.left.normalizedForProfile()
        middleKeys = layout.middle.normalizedForProfile()
        rightKeys = layout.right.normalizedForProfile()
      }
    }
  }

  private func displayText(for key: KBKey) -> String {
    if case .arrows = key.shape {
      return "Arrows"
    }
    switch key.shape.primaryValue {
    case .left:  return "Left Arrow"
    case .right: return "Right Arrow"
    case .up:    return "Up Arrow"
    case .down:  return "Down Arrow"
    default:     return key.shape.primaryText
    }
  }

  // Keys available for left/right sections: modifiers, action icons, arrows, plus char/function keys
  private var sideAvailableKeys: [KBKey] {
    var keys: [KBKey] = [
      .wideKey(.esc, traits: .all),
      .wideKey(.ctrl, traits: .all),
      .wideKey(.alt, traits: .all),
      .wideKey(.cmd, traits: .all),
      .icon(.config, traits: .all),
      .icon(.profileSwitch, traits: .all),
      .icon(.copy, traits: .all),
      .icon(.paste, traits: .all),
      .icon(.dismissKB, traits: .all),
      .arrows(traits: .all),
      .key(.left, traits: .all),
      .key(.right, traits: .all),
      .key(.up, traits: .all),
      .key(.down, traits: .all),
      .key(.tab, traits: .all),
    ]

    let charKeys: [String] = [
      "`", "~", "@", "#", "$", "^", "_",
      "-", "=", "+", "[", "]", "{", "}",
      "\\", "|", "<", ">", "/", "?",
      ".", "!", ",", "%", ";", ":", "&", "'", "\"", "*"
    ]

    for ch in charKeys {
      keys.append(.key(.text(value: ch), traits: .all))
    }

    for n: Int8 in 1...12 {
      keys.append(.key(.f(n), traits: .all))
    }

    return keys
  }

  // Keys available for the middle section (original palette)
  private var middleAvailableKeys: [KBKey] {
    let charKeys: [String] = [
      "`", "~", "@", "#", "$", "^", "_",
      "-", "=", "+", "[", "]", "{", "}",
      "\\", "|", "<", ">", "/", "?",
      ".", "!", ",", "%", ";", ":", "&", "'", "\"", "*"
    ]

    var keys: [KBKey] = [
      .key(.tab, traits: .all),
      .key(.esc, traits: .all),
      .icon(.config, traits: .all),
      .icon(.profileSwitch, traits: .all),
      .icon(.copy, traits: .all),
      .icon(.paste, traits: .all),
      .icon(.dismissKB, traits: .all),
      .key(.ctrl, traits: .all),
      .key(.alt, traits: .all),
      .key(.cmd, traits: .all),
      .arrows(traits: .all),
      .key(.left, traits: .all),
      .key(.right, traits: .all),
      .key(.up, traits: .all),
      .key(.down, traits: .all),
    ]

    for ch in charKeys {
      keys.append(.key(.text(value: ch), traits: .all))
    }

    for n: Int8 in 1...12 {
      keys.append(.key(.f(n), traits: .all))
    }

    return keys
  }

  private func saveProfile() {
    var p: KBToolbarProfile
    if let existing = profile {
      p = existing
      p.name = name.trimmingCharacters(in: .whitespaces)
      p.leftKeys = leftKeys
      p.middleKeys = middleKeys
      p.rightKeys = rightKeys
    } else {
      p = KBToolbarProfile(
        id: UUID(),
        name: name.trimmingCharacters(in: .whitespaces),
        middleKeys: middleKeys,
        leftKeys: leftKeys,
        rightKeys: rightKeys
      )
    }
    manager.save(profile: p)
    if manager.activeProfileId == nil {
      manager.setActiveProfile(id: p.id)
    }
    onSave()
    dismiss()
  }
}
