import Foundation

struct AccountSetupFailure: Error {
  let message: String
  init(_ message: String) { self.message = message }
}

@main struct RecoveryDirectorySwapCheck {
  enum Injected: Error { case stop }
  static func main() throws {
    let fm = FileManager.default
    for original in [true, false] {
      for stop in ["copied", "saved", "published"] {
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("var")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("new".utf8).write(to: source.appendingPathComponent("new.plist"))
        if original {
          try fm.createDirectory(at: target, withIntermediateDirectories: false)
          try Data("old".utf8).write(to: target.appendingPathComponent("stale.plist"))
        }
        do {
          try RecoveryDirectorySwap.replace(
            source: source, target: target, operation: "fixture",
            wasPresent: original, copy: { try fm.copyItem(at: $0, to: $1) },
            checkpoint: { if $0 == stop { throw Injected.stop } })
          preconditionFailure("Expected interruption")
        } catch Injected.stop {}
        try RecoveryDirectorySwap.restore(
          target: target, operation: "fixture", wasPresent: original)
        precondition(fm.fileExists(atPath: target.path) == original)
        if original {
          let bytes = try Data(contentsOf: target.appendingPathComponent("stale.plist"))
          precondition(bytes == Data("old".utf8))
        }
        precondition(!fm.fileExists(atPath: target.appendingPathComponent("new.plist").path))
        // A fresh replacement must remove stale entries, rather than merge trees.
        try RecoveryDirectorySwap.replace(
          source: source, target: target, operation: "second",
          wasPresent: original, copy: { try fm.copyItem(at: $0, to: $1) })
        precondition(!fm.fileExists(atPath: target.appendingPathComponent("stale.plist").path))
        let bytes = try Data(contentsOf: target.appendingPathComponent("new.plist"))
        precondition(bytes == Data("new".utf8))
      }
    }
    print(
      "PASS whole-directory replacement and interruption restore with/without original metadata")
  }
}
