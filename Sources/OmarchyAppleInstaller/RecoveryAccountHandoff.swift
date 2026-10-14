#if os(macOS)
  import CryptoKit
  import Foundation
  import RecoveryAccountCore

  public struct RecoveryAccountReply: Codable, Equatable, Sendable {
    public let ticket: String?
    public let target: RecoveryAccountTarget?
    public let message: String?

    public init(
      ticket: String? = nil, target: RecoveryAccountTarget? = nil, message: String? = nil
    ) {
      self.ticket = ticket
      self.target = target
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

    static func updateRecoveryApp(for target: RecoveryAccountTarget) throws {
      // The helper's own copy first: an app run from its disk image installs
      // one with the helper, while the package leaves the app in /Applications.
      let fm = FileManager.default
      let found = [
        InstallerProductIdentity.installedRecoveryTemplateDirectory + "/Omarchy Installer.app",
        "/Applications/\(InstallerProductIdentity.appName).app/Contents/Resources/RecoveryTemplate/Omarchy Installer.app",
      ].map { URL(fileURLWithPath: $0) }.first { fm.fileExists(atPath: $0.path) }
      guard let source = found else {
        throw AccountSetupFailure(
          "This installer is missing its native Recovery app. Reinstall the updated installer package."
        )
      }
      _ = try AccountNativeCommand.checked(
        "/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path])
      let info = try AccountNativeCommand.disk(target.systemUUID)
      guard (info["VolumeUUID"] as? String)?.uppercased() == target.systemUUID,
        let mount = info["MountPoint"] as? String, mount.hasPrefix("/Volumes/")
      else {
        throw AccountSetupFailure(
          "The completed installation moved before Recovery could be updated.")
      }
      _ = try AccountNativeCommand.checked("/sbin/mount", ["-u", "-w", mount])
      let system = URL(fileURLWithPath: mount, isDirectory: true)
      let destination = system.appendingPathComponent("Omarchy Installer.app", isDirectory: true)
      let oldResources = destination.appendingPathComponent("Contents/Resources", isDirectory: true)
      let configuration = try RecoveryAccountInstaller.protectedRead(
        oldResources.appendingPathComponent("install-config.json"), limit: 65536)
      guard let config = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
        config["systemUUID"] as? String == target.systemUUID,
        config["groupUUID"] as? String == target.groupUUID,
        config["prebootUUID"] as? String == target.prebootUUID
      else { throw AccountSetupFailure("The Recovery app does not match this installation.") }
      try RecoveryAccountInstaller.refreshMountedGroup(target)
      try RecoveryVersionMetadata.hideForInitialRecovery(system: system)
      let executable = "Contents/MacOS/OmarchyRecovery"
      if try Data(contentsOf: destination.appendingPathComponent(executable))
        == Data(contentsOf: source.appendingPathComponent(executable))
      {
        _ = try AccountNativeCommand.checked(
          "/usr/bin/codesign", ["--verify", "--deep", "--strict", destination.path])
        return
      }
      let scratch = system.appendingPathComponent(
        ".omarchy-recovery-update-\(UUID().uuidString)", isDirectory: true)
      try fm.createDirectory(
        at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? fm.removeItem(at: scratch) }
      let candidate = scratch.appendingPathComponent("Omarchy Installer.app", isDirectory: true)
      try fm.copyItem(at: source, to: candidate)
      let resources = candidate.appendingPathComponent("Contents/Resources", isDirectory: true)
      try configuration.write(
        to: resources.appendingPathComponent("install-config.json"), options: .atomic)
      try fm.copyItem(
        at: oldResources.appendingPathComponent("AuraPayloads"),
        to: resources.appendingPathComponent("AuraPayloads"))
      _ = try AccountNativeCommand.checked(
        "/usr/bin/codesign", ["--force", "--sign", "-", candidate.path])
      _ = try AccountNativeCommand.checked(
        "/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path])
      let backup = system.appendingPathComponent(
        "Aurora/Recovery/AppBackups/\(UUID().uuidString).app", isDirectory: true)
      try fm.createDirectory(
        at: backup.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try fm.moveItem(at: destination, to: backup)
      do { try fm.moveItem(at: candidate, to: destination) } catch {
        try fm.moveItem(at: backup, to: destination)
        throw error
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
          found.append(
            CompletedRecoveryInstallation(
              binding: file.deletingPathExtension().lastPathComponent, target: current,
              espUUID: identity.esp))
        }
      }
      // Historical completed journals may name the same still-live target.
      let identities = Set(found.map { $0.target.systemUUID + ":" + $0.espUUID })
      guard identities.count <= 1 else {
        throw AccountSetupFailure(
          "More than one completed installation is waiting for Recovery.")
      }
      return found.first
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
      let path = URL(fileURLWithPath: mount).appendingPathComponent(
        "Omarchy Installer.app/Contents/Resources/install-config.json")
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
      else { throw AccountSetupFailure("The installation volume identities changed.") }
      let target = RecoveryAccountTarget(
        volumeName: name, systemUUID: systemUUID.uppercased(), dataUUID: dataUUID.uppercased(),
        groupUUID: group, prebootUUID: preboot)
      try target.validate()
      return target
    }
  }
#endif
