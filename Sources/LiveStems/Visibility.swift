import Foundation

/// Where Live Stems shows up. At least one place stays on, or nothing could
/// bring the panel back.
enum Visibility {
  private static let dockKey = "showInDock", menuBarKey = "showInMenuBar", hideKey = "hideWhenInactive"
  private static let defaults = UserDefaults.standard
  static var dock: Bool { defaults.object(forKey: dockKey) as? Bool ?? true }
  static var menuBar: Bool { defaults.object(forKey: menuBarKey) as? Bool ?? true }
  /// The panel hides when another app comes forward (Cmd+Tab, a click elsewhere).
  static var hideWhenInactive: Bool {
    get { defaults.object(forKey: hideKey) as? Bool ?? true }
    set { defaults.set(newValue, forKey: hideKey) }
  }
  /// Returns false, and changes nothing, when it would hide both.
  @discardableResult static func setDock(_ on: Bool) -> Bool {
    guard on || menuBar else { return false }
    defaults.set(on, forKey: dockKey)
    return true
  }
  @discardableResult static func setMenuBar(_ on: Bool) -> Bool {
    guard on || dock else { return false }
    defaults.set(on, forKey: menuBarKey)
    return true
  }
  static func reset() {
    defaults.removeObject(forKey: dockKey)
    defaults.removeObject(forKey: menuBarKey)
    defaults.removeObject(forKey: hideKey)
  }
}
