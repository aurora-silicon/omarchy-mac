import Foundation

@main struct RecoveryBaselineCheck {
  enum Fault: Error { case injected }
  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
      "baseline-check-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func write(_ data: Data, _ path: URL) throws {
      try fm.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: path, options: .atomic)
    }
    func refused(line: Int = #line, _ work: () throws -> Void) {
      do {
        try work()
        fatalError("invalid recovery input accepted at test line \(line)")
      } catch {}
    }
    let baseline = root.appendingPathComponent("baseline")
    var files: [String: Data] = [:]
    for name in [RecoveryBaseline.stage2Path] + RecoveryBaseline.vendorPaths {
      files[name] = Data(("new " + name).utf8)
    }
    var metadata: [String: [String: Any]] = [:]
    for (name, data) in files {
      try write(data, baseline.appendingPathComponent(name))
      metadata[name] = ["sha256": RecoveryBaseline.hash(data), "bytes": data.count]
    }
    var manifest: [String: Any] = [
      "files": metadata, "vendorFirmware": RecoveryBaseline.vendorPaths,
    ]
    let firmware = try RecoveryBaseline.firmware(manifest: manifest, root: baseline)
    precondition(firmware.count == 3)
    try write(
      Data("changed".utf8), baseline.appendingPathComponent(RecoveryBaseline.vendorPaths[0]))
    refused { _ = try RecoveryBaseline.firmware(manifest: manifest, root: baseline) }
    try write(
      files[RecoveryBaseline.vendorPaths[0]]!,
      baseline.appendingPathComponent(RecoveryBaseline.vendorPaths[0]))
    for paths in [
      [], ["../firmware.tar"], RecoveryBaseline.vendorPaths + ["vendorfw/unrelated.bin"],
      RecoveryBaseline.vendorPaths + [RecoveryBaseline.vendorPaths[0]],
    ] {
      manifest["vendorFirmware"] = paths
      refused { _ = try RecoveryBaseline.firmware(manifest: manifest, root: baseline) }
    }
    manifest["vendorFirmware"] = RecoveryBaseline.vendorPaths
    let optional = RecoveryBaseline.optionalVendorPath
    let optionalData = Data("optional usb firmware".utf8)
    try write(optionalData, baseline.appendingPathComponent(optional))
    metadata[optional] = [
      "sha256": RecoveryBaseline.hash(optionalData), "bytes": optionalData.count,
    ]
    manifest["files"] = metadata
    manifest["vendorFirmware"] = RecoveryBaseline.vendorPaths + [optional]
    let optionalFirmware = try RecoveryBaseline.firmware(manifest: manifest, root: baseline)
    precondition(optionalFirmware[optional] == optionalData)
    var badMetadata = metadata
    badMetadata[optional] = ["sha256": RecoveryBaseline.hash(Data()), "bytes": 0]
    var badManifest = manifest
    badManifest["files"] = badMetadata
    refused { _ = try RecoveryBaseline.firmware(manifest: badManifest, root: baseline) }
    refused { _ = try RecoveryBaseline.path("../escape", beneath: baseline) }
    try fm.createSymbolicLink(at: baseline.appendingPathComponent("link"), withDestinationURL: root)
    refused { _ = try RecoveryBaseline.path("link/escape", beneath: baseline) }

    for includeOptional in [false, true] {
      let destination = root.appendingPathComponent("success-\(includeOptional)")
      var replacements = files
      if includeOptional { replacements[optional] = optionalData }
      try RecoveryBaseline.restore(
        files: replacements, root: destination,
        backup: root.appendingPathComponent("backup-\(includeOptional)"), write: write)
      for (name, data) in replacements {
        let observed = try Data(contentsOf: destination.appendingPathComponent(name))
        precondition(observed == data)
      }
    }

    let destination = root.appendingPathComponent("rollback")
    let names = files.keys.sorted()
    let originallyMissing = names[1]
    for name in names where name != originallyMissing {
      try write(Data(("old " + name).utf8), destination.appendingPathComponent(name))
    }
    var injected = false
    refused {
      try RecoveryBaseline.restore(
        files: files, root: destination, backup: root.appendingPathComponent("rollback-backup")
      ) { data, path in
        try write(data, path)
        if path == destination.appendingPathComponent(names[2]) && !injected {
          injected = true
          throw Fault.injected
        }
      }
    }
    precondition(injected)
    for name in names {
      if name == originallyMissing {
        precondition(!fm.fileExists(atPath: destination.appendingPathComponent(name).path))
      } else {
        let observed = try Data(contentsOf: destination.appendingPathComponent(name))
        precondition(observed == Data(("old " + name).utf8))
      }
    }
    // A backup failure must prevent the very first ESP write.
    var touched = false
    refused {
      try RecoveryBaseline.restore(
        files: files, root: destination, backup: root.appendingPathComponent("bad-backup")
      ) { _, path in
        if path.path.hasPrefix(destination.path + "/") { touched = true }
        throw Fault.injected
      }
    }
    precondition(!touched)
    let damaged = root.appendingPathComponent("rollback-failure")
    for name in names {
      try write(Data(("old " + name).utf8), damaged.appendingPathComponent(name))
    }
    let rollbackBackup = root.appendingPathComponent("rollback-failure-backup")
    do {
      try RecoveryBaseline.restore(files: files, root: damaged, backup: rollbackBackup) {
        data, path in
        if path == damaged.appendingPathComponent(names[2]) {
          if data == files[names[2]] { try write(data, path) }
          throw Fault.injected
        }
        try write(data, path)
      }
      fatalError("rollback failure was hidden")
    } catch let failure as RecoveryBaselineFailure {
      precondition(
        failure.message.contains("could not restore")
          && failure.message.contains(rollbackBackup.path))
    }
    let firstAfterFailedRollback = try Data(contentsOf: damaged.appendingPathComponent(names[0]))
    precondition(firstAfterFailedRollback == Data(("old " + names[0]).utf8))
    let rollbackRecord =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: rollbackBackup.appendingPathComponent("restore.json")))
      as! [String: Any]
    precondition(rollbackRecord["status"] as? String == "rollback-failed")
    var replacement = files
    replacement["vendorfw/unrelated.bin"] = Data([1])
    refused {
      try RecoveryBaseline.restore(
        files: replacement, root: destination, backup: root.appendingPathComponent("unrelated"),
        write: write)
    }
    print(
      "PASS bounded/hash-checked firmware; required/optional allowlist; complete restore; partial-write rollback; missing-file rollback; backup-before-write"
    )
  }
}
