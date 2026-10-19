#if os(macOS)
  import CryptoKit
  import Foundation
  import RecoveryAccountCore

  public struct RecoveryAccountReply: Codable, Equatable, Sendable {
    public let ticket: String?
    public let target: RecoveryAccountTarget?
    public let record: RecoveryAccountRecord?
    public let message: String?

    public init(
      ticket: String? = nil, target: RecoveryAccountTarget? = nil,
      record: RecoveryAccountRecord? = nil, message: String? = nil
    ) {
      self.ticket = ticket
      self.target = target
      self.record = record
      self.message = message
    }
  }

  struct CompletedRecoveryInstallation: Equatable, Sendable {
    let binding: String
    let target: RecoveryAccountTarget
    let espUUID: String
  }

  enum RecoveryAccountHandoff {
    static func requireStartupSelection(for target: RecoveryAccountTarget) throws {
      let bytes = try AccountNativeCommand.checked(
        "/usr/sbin/bless", ["--getBoot", "--plist"])
      guard
        let selected = try PropertyListSerialization.propertyList(from: bytes, format: nil)
          as? [String: Any], let volume = selected["Boot Volume"] as? String, !volume.isEmpty
      else { throw AccountSetupFailure("Couldn’t verify the selected startup disk.") }
      try requireStartupSelection(target, info: AccountNativeCommand.disk(volume))
    }

    static func requireStartupSelection(_ target: RecoveryAccountTarget, info: [String: Any]) throws
    {
      guard (info["APFSVolumeGroupID"] as? String)?.uppercased() == target.groupUUID else {
        throw AccountSetupFailure(
          "Omarchy is not the selected startup disk. Select Omarchy in Startup Disk, then try Shut Down again."
        )
      }
    }

    private struct AppUpdateJournal: Codable {
      let target: RecoveryAccountTarget
      let backup: String
      let snapshot: String
      let originalFiles: [String]
    }

    private static func appUpdateFiles(_ system: URL) -> [URL] {
      ["SystemVersion.plist", "SystemVersion-disabled.plist"].map {
        system.appendingPathComponent("System/Library/CoreServices/" + $0)
      } + [system.appendingPathComponent(".IAPhysicalMedia")]
    }

    private static func resumeAppUpdate(system: URL, target: RecoveryAccountTarget) throws {
      let fm = FileManager.default
      let state = system.appendingPathComponent("Aurora/Recovery/State")
      let pending = state.appendingPathComponent("app-update.pending.json")
      guard fm.fileExists(atPath: pending.path) else { return }
      let journal = try JSONDecoder().decode(
        AppUpdateJournal.self,
        from: RecoveryAccountInstaller.protectedRead(pending, limit: 65536))
      guard journal.target == target,
        UUID(uuidString: String(journal.backup.dropLast(4))) != nil,
        journal.backup.hasSuffix(".app"), journal.snapshot.hasPrefix("app-update-"),
        UUID(uuidString: String(journal.snapshot.dropFirst("app-update-".count))) != nil,
        [2, 3].contains(journal.originalFiles.count)
      else {
        throw AccountSetupFailure("An interrupted Recovery app update belongs to another target.")
      }
      let snapshot = state.appendingPathComponent(journal.snapshot)
      let transaction = try RecoveryFileTransaction.resume(
        directory: snapshot,
        files: Array(appUpdateFiles(system).prefix(journal.originalFiles.count)),
        originalFiles: journal.originalFiles.map { URL(fileURLWithPath: $0) })
      let status = try? Data(contentsOf: snapshot.appendingPathComponent("status"))
      if status != Data("committed\n".utf8) {
        try transaction.restore()
        let backup = system.appendingPathComponent("Aurora/Recovery/AppBackups/" + journal.backup)
        let destination = system.appendingPathComponent(
          InstallerProductIdentity.recoveryAppBundleName)
        if fm.fileExists(atPath: backup.path) {
          if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
          try fm.moveItem(at: backup, to: destination)
          try RecoveryFileTransaction.flushDirectory(system)
          try RecoveryFileTransaction.flushDirectory(backup.deletingLastPathComponent())
        }
        let identity = backup.appendingPathExtension("json")
        if fm.fileExists(atPath: identity.path) { try fm.removeItem(at: identity) }
      }
      try fm.removeItem(at: pending)
      try RecoveryFileTransaction.flushDirectory(state)
    }

    static func updateRecoveryApp(for target: RecoveryAccountTarget) throws {
      // The helper's own copy first: an app run from its disk image installs
      // one with the helper, while the package leaves the app in /Applications.
      let fm = FileManager.default
      let found = [
        InstallerProductIdentity.installedRecoveryTemplateDirectory + "/"
          + InstallerProductIdentity.recoveryAppBundleName,
        "/Applications/\(InstallerProductIdentity.appName).app/Contents/Resources/RecoveryTemplate/\(InstallerProductIdentity.recoveryAppBundleName)",
      ].map { URL(fileURLWithPath: $0) }.first { fm.fileExists(atPath: $0.path) }
      guard let source = found else {
        throw AccountSetupFailure(
          "This installer is missing its native Recovery app. Reinstall the updated installer package."
        )
      }
      guard
        let requirement = NativeRecoveryTemplate.requirement(
          environment: ProcessInfo.processInfo.environment)
      else {
        throw AccountSetupFailure(
          "The helper has no verified Recovery-template identity. Reinstall this build’s helper.")
      }
      _ = try AccountNativeCommand.checked(
        "/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=" + requirement, source.path])
      guard
        let templateInfo = try PropertyListSerialization.propertyList(
          from: Data(contentsOf: source.appendingPathComponent("Contents/Info.plist")), format: nil)
          as? [String: Any],
        templateInfo["OmarchyRecoveryDataLayout"] as? String == "external-install-data-v1"
      else { throw AccountSetupFailure("The Recovery template uses an incompatible data layout.") }
      let info = try AccountNativeCommand.disk(target.systemUUID)
      guard (info["VolumeUUID"] as? String)?.uppercased() == target.systemUUID,
        let mount = info["MountPoint"] as? String, mount.hasPrefix("/Volumes/")
      else {
        throw AccountSetupFailure(
          "The completed installation moved before Recovery could be updated.")
      }
      _ = try AccountNativeCommand.checked("/sbin/mount", ["-u", "-w", mount])
      let system = URL(fileURLWithPath: mount, isDirectory: true)
      let destination = system.appendingPathComponent(
        InstallerProductIdentity.recoveryAppBundleName, isDirectory: true)
      try resumeAppUpdate(system: system, target: target)
      let configuration = try RecoveryAccountInstaller.protectedRead(
        RecoveryInstallData.configuration(
          system: system, appName: InstallerProductIdentity.recoveryAppBundleName), limit: 65536)
      guard let config = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
        config["systemUUID"] as? String == target.systemUUID,
        config["groupUUID"] as? String == target.groupUUID,
        config["prebootUUID"] as? String == target.prebootUUID
      else { throw AccountSetupFailure("The Recovery app does not match this installation.") }
      try RecoveryAccountInstaller.refreshMountedGroup(target)
      // Complete a verified legacy-data migration before swapping the app. If
      // an app update rolls back, the old bundle and this baseline both survive.
      try RecoveryInstallData.migrateLegacy(
        system: system, appName: InstallerProductIdentity.recoveryAppBundleName, target: target)
      let scratch = system.appendingPathComponent(
        ".omarchy-recovery-update-\(UUID().uuidString)", isDirectory: true)
      try fm.createDirectory(
        at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? fm.removeItem(at: scratch) }
      let candidate = scratch.appendingPathComponent(
        InstallerProductIdentity.recoveryAppBundleName, isDirectory: true)
      try fm.copyItem(at: source, to: candidate)
      _ = try AccountNativeCommand.checked(
        "/usr/bin/codesign",
        ["--verify", "--deep", "--strict", "-R=" + requirement, candidate.path])
      let backup = system.appendingPathComponent(
        "Aurora/Recovery/AppBackups/\(UUID().uuidString).app", isDirectory: true)
      try fm.createDirectory(
        at: backup.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let state = system.appendingPathComponent("Aurora/Recovery/State")
      try fm.createDirectory(
        at: state, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let snapshot = state.appendingPathComponent("app-update-" + UUID().uuidString)
      let files = appUpdateFiles(system)
      let transaction = try RecoveryFileTransaction(directory: snapshot, files: files)
      let pending = state.appendingPathComponent("app-update.pending.json")
      try RecoveryFileTransaction.write(
        try JSONEncoder().encode(
          AppUpdateJournal(
            target: target, backup: backup.lastPathComponent, snapshot: snapshot.lastPathComponent,
            originalFiles: files.map(\.path))), to: pending)
      do {
        // Keep the target binding beside the immutable backup, never inside it.
        try RecoveryFileTransaction.write(
          try JSONEncoder().encode(target), to: backup.appendingPathExtension("json"))
        try fm.moveItem(at: destination, to: backup)
        try RecoveryFileTransaction.flushDirectory(system)
        try RecoveryFileTransaction.flushDirectory(backup.deletingLastPathComponent())
        try fm.moveItem(at: candidate, to: destination)
        try RecoveryFileTransaction.flushDirectory(system)
        let receipt = system.appendingPathComponent(recoveryReceiptPath)
        if let bytes = try? RecoveryAccountInstaller.protectedRead(receipt, limit: 65536),
          let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          value["recoveryAccountDeferred"] as? Bool == true
        {
          let saved = try RecoveryAccountInstaller.protectedRead(
            system.appendingPathComponent("IAPhysicalMedia-disabled.plist"), limit: 65536)
          guard
            let launch = try PropertyListSerialization.propertyList(from: saved, format: nil)
              as? [String: Any],
            launch["AppName"] as? String == InstallerProductIdentity.recoveryAppBundleName
          else { throw AccountSetupFailure("The deferred Recovery launcher is unavailable.") }
          try RecoveryFileTransaction.write(
            saved, to: system.appendingPathComponent(".IAPhysicalMedia"))
        }
        let movesVersion =
          fm.fileExists(atPath: files[0].path)
          && fm.fileExists(atPath: system.appendingPathComponent(".IAPhysicalMedia").path)
        try RecoveryVersionMetadata.hideForInitialRecovery(system: system)
        try transaction.commit(relocated: movesVersion ? [files[0].path: files[1]] : [:])
        try fm.removeItem(at: pending)
        try RecoveryFileTransaction.flushDirectory(state)
      } catch {
        let original = error
        try resumeAppUpdate(system: system, target: target)
        throw original
      }
      // Keep two previous GUI versions. Per-install inputs stay in InstallData.
      let backups = backup.deletingLastPathComponent()
      let versions = try fm.contentsOfDirectory(
        at: backups, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      ).filter {
        $0.pathExtension == "app"
          && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
      }
      let ordered = versions.sorted {
        ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast)
          > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast)
      }
      for obsolete in ordered.dropFirst(2) {
        let identity = obsolete.appendingPathExtension("json")
        if let bytes = try? RecoveryAccountInstaller.protectedRead(identity, limit: 65536),
          let owner = try? JSONDecoder().decode(RecoveryAccountTarget.self, from: bytes),
          owner.systemUUID == target.systemUUID, owner.groupUUID == target.groupUUID,
          owner.prebootUUID == target.prebootUUID
        {
          try? fm.removeItem(at: obsolete)
          try? fm.removeItem(at: identity)
          continue
        }
        // Older backups predate the external baseline and carry their binding.
        let config = try? RecoveryAccountInstaller.protectedRead(
          obsolete.appendingPathComponent("Contents/Resources/install-config.json"), limit: 65536)
        if let config,
          let object = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
          object["groupUUID"] as? String == target.groupUUID
        {
          try? fm.removeItem(at: obsolete)
        }
      }
    }

    static func completedEvidence(transcript: Data, evidence: [String: Data]) throws -> (
      group: String, esp: String
    ) {
      guard transcript.last == 10 else {
        throw AccountSetupFailure("The completed installation record is incomplete.")
      }
      let lines = transcript.split(separator: 10)
      guard lines.count >= 10, lines.count <= 32 else {
        throw AccountSetupFailure("The completed installation record is unsuitable.")
      }
      var records = [[String: Any]]()
      for (index, line) in lines.enumerated() {
        guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
          Set(object.keys) == ["schema_version", "sequence", "type", "payload"],
          object["schema_version"] as? Int == 1, object["sequence"] as? Int == index + 1,
          object["payload"] is [String: Any]
        else { throw AccountSetupFailure("The completed installation record is invalid.") }
        records.append(object)
      }
      guard records[2]["type"] as? String == "plan",
        let plan = records[2]["payload"] as? [String: Any],
        let digest = plan["plan_digest"] as? String,
        records.last?["type"] as? String == "completion",
        let completion = records.last?["payload"] as? [String: Any],
        completion["plan_digest"] as? String == digest,
        completion["outcome"] as? String == "awaiting_recovery"
      else { throw AccountSetupFailure("This installation has not completed its first step.") }
      let identifiers = [
        "apfs-target-prepared", "stub-and-esp-installed", "recovery-handoff-prepared",
      ]
      for identifier in identifiers {
        let matches = records.filter {
          ($0["type"] as? String) == "checkpoint"
            && ($0["payload"] as? [String: Any])?["identifier"] as? String == identifier
        }
        guard matches.count == 1, let checkpoint = matches[0]["payload"] as? [String: Any],
          checkpoint["plan_digest"] as? String == digest, let bytes = evidence[identifier],
          checkpoint["evidence_digest"] as? String == "sha256:"
            + SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined(),
          let saved = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          saved["plan_digest"] as? String == digest
        else { throw AccountSetupFailure("A completed installation checkpoint did not verify.") }
      }
      guard let bytes = evidence["stub-and-esp-installed"],
        let installed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
        let group = installed["apfs_vgid"] as? String,
        let esp = installed["efi_partition"] as? String,
        UUID(uuidString: group) != nil, UUID(uuidString: esp) != nil,
        let parts = installed["populated_partitions"] as? [[String: Any]], parts.count == 3,
        parts.map({ $0["name"] as? String }) == ["EFI", "Boot", "Root"],
        parts[0]["partition_uuid"] as? String == esp
      else { throw AccountSetupFailure("The installed volume identities are incomplete.") }
      return (group.uppercased(), esp.uppercased())
    }

    static func discover(in workingDirectory: URL, binding: String? = nil) throws
      -> CompletedRecoveryInstallation?
    {
      let directory = workingDirectory.appendingPathComponent(
        "execution-journals", isDirectory: true)
      guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
      let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
      ).filter {
        $0.lastPathComponent.range(of: "\\A[a-f0-9]{64}\\.jsonl\\z", options: .regularExpression)
          != nil
          && (binding == nil || $0.deletingPathExtension().lastPathComponent == binding)
      }
      guard files.count <= 128 else {
        throw AccountSetupFailure("Too many installation records need review.")
      }
      let diskBytes = try AccountNativeCommand.checked("/usr/sbin/diskutil", ["list", "-plist"])
      guard
        let diskList = try PropertyListSerialization.propertyList(
          from: diskBytes, format: nil) as? [String: Any]
      else { throw AccountSetupFailure("Couldn’t inspect the installed partitions.") }
      var found = [CompletedRecoveryInstallation]()
      for file in files {
        do {
          let bytes = try RecoveryAccountInstaller.protectedRead(file, limit: 4 << 20)
          let ended = bytes.split(separator: 10).last.flatMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
          }
          guard ended?["type"] as? String == "completion" else { continue }
          var evidence = [String: Data]()
          for identifier in [
            "apfs-target-prepared", "stub-and-esp-installed", "recovery-handoff-prepared",
          ] {
            evidence[identifier] = try RecoveryAccountInstaller.protectedRead(
              URL(fileURLWithPath: file.path + ".\(identifier).evidence"), limit: 65536)
          }
          let identity = try completedEvidence(transcript: bytes, evidence: evidence)
          if let current = try? liveTarget(group: identity.group, esp: identity.esp) {
            do {
              try requireLivePartitions(evidence: evidence, listing: diskList)
            } catch { continue }
            // Recovery already finished this one: it is installed, not waiting.
            if recoveryFinished(current) { continue }
            found.append(
              CompletedRecoveryInstallation(
                binding: file.deletingPathExtension().lastPathComponent, target: current,
                espUUID: identity.esp))
          }
        } catch {
          // A historical or incomplete record is not a current handoff.
          continue
        }
      }
      // Historical completed journals may name the same still-live target.
      let identities = Set(found.map { $0.target.systemUUID + ":" + $0.espUUID })
      guard identities.count <= 1 else {
        throw AccountSetupFailure(
          "Choose which completed installation should receive a recovery account.")
      }
      return found.first
    }

    /// Recovery's Finish Installation writes this receipt on the installed
    /// System volume only after it has authorized and enrolled the boot.
    static let recoveryReceiptPath = "Aurora/Recovery/State/installation.json"

    static func isFinishedRecoveryReceipt(_ data: Data, hasPendingOperation: Bool = false) -> Bool {
      guard !hasPendingOperation,
        let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return false }
      return receipt["status"] as? String == "installed"
        && receipt["recoveryAccountDeferred"] as? Bool != true
    }

    /// Whether Recovery completed the installation on `target`. The System
    /// volume is mounted read-only to look, if macOS has not mounted it.
    static func recoveryFinished(_ target: RecoveryAccountTarget) -> Bool {
      guard var info = try? AccountNativeCommand.disk(target.systemUUID) else { return false }
      if (info["MountPoint"] as? String ?? "").isEmpty {
        _ = try? AccountNativeCommand.checked(
          "/usr/sbin/diskutil", ["mount", "readOnly", target.systemUUID])
        guard let mounted = try? AccountNativeCommand.disk(target.systemUUID) else { return false }
        info = mounted
      }
      guard let mount = info["MountPoint"] as? String, !mount.isEmpty,
        let receipt = try? RecoveryAccountInstaller.protectedRead(
          URL(fileURLWithPath: mount).appendingPathComponent(recoveryReceiptPath), limit: 65536)
      else { return false }
      let pending = URL(fileURLWithPath: mount).appendingPathComponent(
        "Aurora/Recovery/State/installation.pending.json")
      return isFinishedRecoveryReceipt(
        receipt,
        hasPendingOperation: FileManager.default.fileExists(atPath: pending.path)
          || (try? FileManager.default.destinationOfSymbolicLink(atPath: pending.path)) != nil)
    }

    static func requireLivePartitions(evidence: [String: Data], listing: [String: Any]) throws {
      guard let targetBytes = evidence["apfs-target-prepared"],
        let installedBytes = evidence["stub-and-esp-installed"],
        let target = try JSONSerialization.jsonObject(with: targetBytes) as? [String: Any],
        let installed = try JSONSerialization.jsonObject(with: installedBytes) as? [String: Any],
        let targetID = target["uuid"] as? String, let targetSize = target["size_bytes"] as? UInt64,
        let parts = installed["populated_partitions"] as? [[String: Any]], parts.count == 3,
        let disks = listing["AllDisksAndPartitions"] as? [[String: Any]]
      else { throw AccountSetupFailure("The installation’s partition record is incomplete.") }
      let live = disks.flatMap { $0["Partitions"] as? [[String: Any]] ?? [] }
      var required = [(targetID, targetSize)]
      for part in parts {
        guard let id = part["partition_uuid"] as? String,
          let size = part["partition_size_bytes"] as? UInt64
        else { throw AccountSetupFailure("The installation’s partition record is incomplete.") }
        required.append((id, size))
      }
      guard Set(required.map { $0.0.lowercased() }).count == 4 else {
        throw AccountSetupFailure("The installation’s partition identities are ambiguous.")
      }
      for (id, size) in required {
        let matches = live.filter { ($0["DiskUUID"] as? String)?.lowercased() == id.lowercased() }
        guard UUID(uuidString: id) != nil, size > 0, matches.count == 1,
          matches[0]["Size"] as? UInt64 == size
        else {
          throw AccountSetupFailure("The recorded installation partitions are absent or changed.")
        }
      }
    }

    private static func liveTarget(group: String, esp: String) throws -> RecoveryAccountTarget {
      let bytes = try AccountNativeCommand.checked(
        "/usr/sbin/diskutil", ["apfs", "list", "-plist"])
      guard
        let tree = try PropertyListSerialization.propertyList(from: bytes, format: nil)
          as? [String: Any], let containers = tree["Containers"] as? [[String: Any]]
      else { throw AccountSetupFailure("Couldn’t inspect the installation volumes.") }
      var system: [String: Any]?
      var data: [String: Any]?
      for container in containers {
        for volume in container["Volumes"] as? [[String: Any]] ?? [] {
          let roles = volume["Roles"] as? [String] ?? []
          guard roles.contains("System") || roles.contains("Data"),
            let uuid = volume["APFSVolumeUUID"] as? String
          else { continue }
          let info = try AccountNativeCommand.disk(uuid)
          guard (info["APFSVolumeGroupID"] as? String)?.uppercased() == group else { continue }
          if roles.contains("System") {
            guard system == nil else {
              throw AccountSetupFailure("The System volume is ambiguous.")
            }
            system = info
          }
          if roles.contains("Data") {
            guard data == nil else { throw AccountSetupFailure("The Data volume is ambiguous.") }
            data = info
          }
        }
      }
      guard var system, let data, let systemUUID = system["VolumeUUID"] as? String,
        let dataUUID = data["VolumeUUID"] as? String
      else { throw AccountSetupFailure("The completed installation is no longer present.") }
      if (system["MountPoint"] as? String)?.isEmpty != false {
        _ = try AccountNativeCommand.checked(
          "/usr/sbin/diskutil", ["mount", "readOnly", systemUUID])
        system = try AccountNativeCommand.disk(systemUUID)
      }
      guard let mount = system["MountPoint"] as? String else {
        throw AccountSetupFailure("Couldn’t mount the completed installation.")
      }
      let path = try RecoveryInstallData.configuration(
        system: URL(fileURLWithPath: mount), appName: InstallerProductIdentity.recoveryAppBundleName
      )
      let configBytes = try RecoveryAccountInstaller.protectedRead(path, limit: 65536)
      guard let config = try JSONSerialization.jsonObject(with: configBytes) as? [String: Any],
        config["schema"] as? Int == 2,
        config["systemUUID"] as? String == systemUUID.uppercased(),
        config["groupUUID"] as? String == group, config["espUUID"] as? String == esp,
        let preboot = config["prebootUUID"] as? String,
        let name = system["VolumeName"] as? String
      else { throw AccountSetupFailure("The staged Recovery app belongs to another installation.") }
      let boot = try AccountNativeCommand.disk(preboot)
      let efi = try AccountNativeCommand.disk(esp)
      guard (efi["DiskUUID"] as? String)?.uppercased() == esp,
        system["APFSContainerReference"] as? String == data["APFSContainerReference"] as? String,
        system["APFSContainerReference"] as? String == boot["APFSContainerReference"] as? String
      else { throw AccountSetupFailure("The recovery account volume identities changed.") }
      let target = RecoveryAccountTarget(
        volumeName: name, systemUUID: systemUUID.uppercased(), dataUUID: dataUUID.uppercased(),
        groupUUID: group, prebootUUID: preboot)
      try target.validate()
      return target
    }
  }
#endif
