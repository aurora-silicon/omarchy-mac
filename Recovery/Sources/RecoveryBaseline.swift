import CryptoKit
import Foundation

struct RecoveryBaselineFailure: Error, LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

enum RecoveryBaseline {
  static let vendorPaths = [
    "vendorfw/firmware.tar", "vendorfw/firmware.cpio", "vendorfw/manifest.txt",
  ]
  static let stage2Path = "m1n1/boot.bin"
  static let optionalVendorPath = "vendorfw/u-boot/asmedia/asm2214a-apple.bin"

  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func limit(_ name: String) -> Int {
    if name == "vendorfw/manifest.txt" { return 1 << 20 }
    return name == optionalVendorPath ? 16 << 20 : 256 << 20
  }

  static func path(_ name: String, beneath root: URL) throws -> URL {
    guard !name.isEmpty, !name.contains("\0"),
      name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".."
      })
    else { throw RecoveryBaselineFailure(message: "Invalid recovery file path.") }
    let base = root.resolvingSymlinksInPath().standardizedFileURL
    let destination = base.appendingPathComponent(name)
    // Foundation may leave a path unresolved when the final file does not
    // exist. Inspect every parent as well, including dangling symlinks.
    var component = base
    for part in name.split(separator: "/") {
      component.appendPathComponent(String(part))
      if (try? FileManager.default.destinationOfSymbolicLink(atPath: component.path)) != nil {
        throw RecoveryBaselineFailure(message: "A recovery file path is a symbolic link: \(name)")
      }
    }
    guard destination.resolvingSymlinksInPath().standardizedFileURL.path == destination.path else {
      throw RecoveryBaselineFailure(message: "A recovery file path is a symbolic link: \(name)")
    }
    return destination
  }

  static func read(_ url: URL, maximum: Int, allowEmpty: Bool = false) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? NSNumber,
      size.int64Value <= Int64(maximum), size.int64Value >= (allowEmpty ? 0 : 1)
    else {
      throw RecoveryBaselineFailure(
        message: "Invalid recovery file size or type: \(url.lastPathComponent)")
    }
    let data = try Data(contentsOf: url)
    guard data.count == size.intValue else {
      throw RecoveryBaselineFailure(message: "A recovery file changed while reading it.")
    }
    return data
  }

  static func asset(_ name: String, manifest: [String: Any], root: URL) throws -> Data {
    guard let files = manifest["files"] as? [String: [String: Any]],
      let record = files[name], let expected = record["sha256"] as? String,
      expected.count == 64, expected.allSatisfy({ "0123456789abcdef".contains($0) }),
      let size = record["bytes"] as? Int, size > 0, size <= limit(name)
    else { throw RecoveryBaselineFailure(message: "A required recovery file is missing: \(name)") }
    let data = try read(path(name, beneath: root), maximum: limit(name))
    guard data.count == size, hash(data) == expected else {
      throw RecoveryBaselineFailure(message: "A recovery file failed its checksum: \(name)")
    }
    return data
  }

  static func firmware(manifest: [String: Any], root: URL) throws -> [String: Data] {
    guard let paths = manifest["vendorFirmware"] as? [String],
      paths.count == Set(paths).count, Set(vendorPaths).isSubset(of: Set(paths)),
      Set(paths).isSubset(of: Set(vendorPaths + [optionalVendorPath]))
    else {
      throw RecoveryBaselineFailure(message: "The recovery device firmware package is incomplete.")
    }
    var files: [String: Data] = [:]
    for name in paths { files[name] = try asset(name, manifest: manifest, root: root) }
    return files
  }

  // All backups finish before the first ESP write. Include the currently
  // attempted file in rollback because a writer can fail after replacing it.
  static func restore(
    files: [String: Data], root: URL, backup: URL,
    write: (Data, URL) throws -> Void
  ) throws {
    let required = Set([stage2Path] + vendorPaths)
    let names = files.keys.sorted()
    guard required.isSubset(of: Set(names)),
      Set(names).isSubset(of: required.union([optionalVendorPath]))
    else {
      throw RecoveryBaselineFailure(
        message: "Recovery may restore only Stage 2 and its device firmware package.")
    }
    for name in names {
      guard let data = files[name], !data.isEmpty, data.count <= limit(name) else {
        throw RecoveryBaselineFailure(message: "Invalid replacement recovery file: \(name)")
      }
    }
    let fm = FileManager.default
    var previous: [String: Data] = [:]
    var destinations: [String: URL] = [:]
    var records: [String: [String: Any]] = [:]
    for name in names {
      let destination = try path(name, beneath: root)
      destinations[name] = destination
      if fm.fileExists(atPath: destination.path) {
        let data = try read(destination, maximum: limit(name), allowEmpty: true)
        previous[name] = data
        try write(data, path(name, beneath: backup))
        records[name] = ["existed": true, "sha256": hash(data), "bytes": data.count]
      } else {
        records[name] = ["existed": false]
      }
    }
    let journal = backup.appendingPathComponent("restore.json")
    func record(_ status: String) throws {
      let data = try JSONSerialization.data(
        withJSONObject: ["schema": 1, "status": status, "files": records],
        options: [.prettyPrinted, .sortedKeys])
      try write(data, journal)
    }
    try record("prepared")
    var attempted: [String] = []
    do {
      for name in names {
        attempted.append(name)
        try write(files[name]!, destinations[name]!)
      }
      try record("restored")
    } catch {
      let original = error
      var failures: [String] = []
      for name in attempted.reversed() {
        do {
          if let data = previous[name] {
            try write(data, destinations[name]!)
          } else if fm.fileExists(atPath: destinations[name]!.path) {
            try fm.removeItem(at: destinations[name]!)
          }
        } catch { failures.append(name) }
      }
      try? record(failures.isEmpty ? "rolled-back" : "rollback-failed")
      if !failures.isEmpty {
        throw RecoveryBaselineFailure(
          message:
            "Recovery failed and could not restore \(failures.joined(separator: ", ")). Backups: \(backup.path)"
        )
      }
      throw original
    }
  }
}
