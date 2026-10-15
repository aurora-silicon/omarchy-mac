#if os(macOS)
  import Foundation

  /// What removal found between macOS and Apple Recovery. Recognition is by
  /// structure; names are only reported. Files on the installation then have
  /// to confirm it (RemovalEvidence) before a plan exists.
  enum RemovalLayout {
    case freeSpace(macOS: RemovalPartition, target: UInt64)
    case installation(RemovalInstallation, macOS: RemovalPartition, target: UInt64)

    static let minimumFreeSpace: UInt64 = 1 << 30
    static let memberGap: UInt64 = 16 << 20
    // asahi-installer's STUB_SIZE is 2,499,805,184 bytes; a stub on macOS 26
    // firmware (the MacBook Neo) is 5,999,951,872.
    static let stubSizes: [ClosedRange<UInt64>] = [
      2_300_000_000...2_700_000_000, 5_800_000_000...6_200_000_000,
    ]
    static let maximumESP: UInt64 = 1 << 30

    static func recognize(_ snapshot: RemovalSnapshot) throws -> RemovalLayout {
      let parts = snapshot.partitions.sorted { $0.offset < $1.offset }
      guard !parts.isEmpty, parts.count <= 32,
        Set(parts.map(\.uuid)).count == parts.count,
        parts.allSatisfy({ $0.size > 0 && !$0.offset.addingReportingOverflow($0.size).overflow }),
        zip(parts, parts.dropFirst()).allSatisfy({ $0.end <= $1.offset }),
        parts[parts.count - 1].end <= snapshot.diskSize
      else {
        throw RemovalFailure(message: RemovalText.inconsistent(parts, snapshot))
      }
      guard parts.count >= 3, parts[0].type == "Apple_APFS_ISC",
        parts[parts.count - 1].type == "Apple_APFS_Recovery",
        parts[1].type == "Apple_APFS", parts[1].uuid == snapshot.macOSStoreUUID,
        snapshot.containers.filter({
          $0.storeUUID == parts[1].uuid && $0.uuid == snapshot.macOSContainerUUID
        }).count == 1
      else {
        throw RemovalFailure(message: RemovalText.unexpectedFrame(parts, snapshot))
      }
      let macOS = parts[1]
      let recovery = parts[parts.count - 1]
      let target = recovery.offset - macOS.offset
      let middle = Array(parts[2..<(parts.count - 1)])
      if middle.isEmpty {
        let gap = recovery.offset - macOS.end
        guard gap >= minimumFreeSpace else {
          throw RemovalFailure(message: RemovalText.nothingFound(gap: gap))
        }
        return .freeSpace(macOS: macOS, target: target)
      }

      let stranded = strandedFreeSpace(middle: middle, recovery: recovery)
      func refuse(_ finding: String) -> RemovalFailure {
        RemovalFailure(message: RemovalText.refusal(finding, stranded: stranded, snapshot))
      }
      let kinds = middle.map { classify($0, snapshot) }
      let others = zip(middle, kinds).filter { $0.1 == .otherSystem }.map(\.0)
      if !others.isEmpty { throw refuse(RemovalText.otherSystem(others, snapshot)) }
      let foreign = zip(middle, kinds).filter { $0.1 == .foreign }.map(\.0)
      if !foreign.isEmpty { throw refuse(RemovalText.foreign(foreign, snapshot)) }
      let stubs = zip(middle, kinds).filter { $0.1 == .stub }.map(\.0)
      if stubs.count > 1 { throw refuse(RemovalText.several(stubs, snapshot)) }
      if stubs.isEmpty { throw refuse(RemovalText.partial(middle, snapshot)) }
      guard middle.count >= 2, middle.count <= 4, kinds[0] == .stub, kinds[1] == .esp,
        kinds.dropFirst(2).allSatisfy({ $0 == .linux }),
        middle[1].size <= maximumESP,
        zip(middle, middle.dropFirst()).allSatisfy({ $1.offset - $0.end < memberGap })
      else { throw refuse(RemovalText.shape(middle, snapshot)) }
      let stub = middle[0]
      let container = snapshot.containers.first { $0.storeUUID == stub.uuid }!
      let system = container.volumes.first { $0.roles == ["System"] }!
      return .installation(
        RemovalInstallation(
          name: system.name, stub: stub, system: system, esp: middle[1],
          linux: Array(middle.dropFirst(2))),
        macOS: macOS, target: target)
    }

    enum Kind: Equatable { case stub, esp, linux, otherSystem, foreign }

    static func classify(_ part: RemovalPartition, _ snapshot: RemovalSnapshot) -> Kind {
      switch part.type {
      case "EFI": return .esp
      case "Linux Filesystem": return .linux
      case "Apple_APFS":
        let containers = snapshot.containers.filter { $0.storeUUID == part.uuid }
        guard containers.count == 1 else { return .foreign }
        let volumes = containers[0].volumes
        let systems = volumes.filter { $0.roles == ["System"] }
        let data = volumes.filter { $0.roles == ["Data"] }
        guard !systems.isEmpty, !data.isEmpty else { return .foreign }
        guard stubSizes.contains(where: { $0.contains(part.size) }), volumes.count == 4,
          systems.count == 1,
          data.count == 1, let group = systems[0].group, data[0].group == group,
          volumes.filter({ $0.roles == ["Preboot"] }).count == 1,
          volumes.filter({ $0.roles == ["Recovery"] }).count == 1
        else { return .otherSystem }
        return .stub
      default: return .foreign
      }
    }

    /// Unallocated space ≥ 1 GiB that sits behind a partition, so macOS can't grow into it.
    static func strandedFreeSpace(middle: [RemovalPartition], recovery: RemovalPartition)
      -> (bytes: UInt64, behind: [RemovalPartition])?
    {
      var total: UInt64 = 0
      let edges = middle + [recovery]
      for (index, part) in middle.enumerated() {
        total += edges[index + 1].offset - part.end
      }
      return total >= minimumFreeSpace ? (total, middle) : nil
    }
  }

  struct RemovalCreatedPartition: Codable, Equatable, Hashable, Sendable {
    let uuid: String
    let type: String
  }

  enum RemovalInstallerRecord: Codable, Equatable, Sendable {
    case missing
    case unreadable
    case partitions([RemovalCreatedPartition])
  }

  /// Raw files read from the installation's EFI partition and startup container.
  struct RemovalInstallFiles: Sendable {
    var espBootObject: Data?
    var stubInfo: Data?
    var installerLog: Data?
    var stubHasLibrary: Bool
    var stubBootObject: Data?
  }

  /// What the files prove, without keeping their contents (stub_info.json names
  /// the Mac's administrators). Digests let execution recheck the exact files.
  struct RemovalEvidence: Codable, Equatable, Sendable {
    let espBootObject: SHA256Digest?
    let stubInfo: SHA256Digest?
    let stubVolumeGroup: String?
    let installerLog: SHA256Digest?
    let installerRecord: RemovalInstallerRecord
    let stubHasLibrary: Bool
    let stubBootObject: SHA256Digest?
    let stubHasM1n1: Bool
    let stubEFIPartitions: [String]?

    init(files: RemovalInstallFiles) {
      espBootObject = files.espBootObject.map(SHA256Digest.init(hashing:))
      stubInfo = files.stubInfo.map(SHA256Digest.init(hashing:))
      stubVolumeGroup = files.stubInfo.flatMap(Self.volumeGroup(stubInfo:))
      installerLog = files.installerLog.map(SHA256Digest.init(hashing:))
      installerRecord =
        files.installerLog.map {
          Self.createdPartitions(log: $0).map { .partitions($0) } ?? .unreadable
        }
        ?? .missing
      stubHasLibrary = files.stubHasLibrary
      stubBootObject = files.stubBootObject.map(SHA256Digest.init(hashing:))
      stubHasM1n1 =
        files.stubBootObject.map { $0.range(of: Data("##m1n1_ver##".utf8)) != nil } ?? false
      stubEFIPartitions = files.stubBootObject.flatMap(Self.efiPartitions(bootObject:))
    }

    /// nil when every check passes; otherwise the first check that failed, as a phrase.
    func problem(for installation: RemovalInstallation) -> String? {
      guard espBootObject != nil else { return "its EFI partition has no m1n1/boot.bin" }
      guard stubInfo != nil, let stubVolumeGroup else {
        return "its EFI partition has no readable asahi/stub_info.json"
      }
      guard stubVolumeGroup == installation.system.group else {
        return
          "the asahi/stub_info.json on its EFI partition names a different startup container"
      }
      switch installerRecord {
      case .missing:
        return "its EFI partition has no installer record (asahi/installer.log)"
      case .unreadable:
        return
          "the installer record on its EFI partition (asahi/installer.log) has entries that couldn’t be read"
      case .partitions(let created):
        let found = installation.members.map {
          RemovalCreatedPartition(uuid: $0.uuid, type: $0.type)
        }
        let extra = installation.members.filter {
          !created.contains(RemovalCreatedPartition(uuid: $0.uuid, type: $0.type))
        }
        let missing = created.filter { !found.contains($0) }
        if !extra.isEmpty || !missing.isEmpty {
          var parts = [String]()
          if !extra.isEmpty {
            parts.append(
              "\(extra.map(\.identifier).joined(separator: ", ")) \(extra.count == 1 ? "wasn’t" : "weren’t") created by that installer"
            )
          }
          if !missing.isEmpty {
            parts.append(
              "\(missing.count) partition\(missing.count == 1 ? "" : "s") it created \(missing.count == 1 ? "is" : "are") gone"
            )
          }
          return
            "the installer record on its EFI partition doesn’t match the disk: \(parts.joined(separator: "; "))"
        }
      }
      guard !stubHasLibrary else {
        return
          "its startup container holds a full system (a Library folder), unlike a startup container made by the Asahi installer"
      }
      guard stubBootObject != nil else {
        return "its startup container has no m1n1 boot object (Finish Installation.app)"
      }
      guard stubHasM1n1 else { return "the boot object in its startup container isn’t m1n1" }
      guard let links = stubEFIPartitions, links.count == 1,
        let link = UUID(uuidString: links[0]), link.uuidString == installation.esp.uuid
      else {
        return
          "the m1n1 boot object in its startup container doesn’t point to this EFI partition"
      }
      return nil
    }

    static func volumeGroup(stubInfo: Data) -> String? {
      guard let object = try? JSONSerialization.jsonObject(with: stubInfo) as? [String: Any],
        let raw = object["vgid"] as? String, let uuid = UUID(uuidString: raw)
      else { return nil }
      return uuid.uuidString
    }

    /// asahi-installer logs `New partition: Partition(name=..., type=..., uuid=...)`
    /// for every partition it adds, and copies the log to the ESP's asahi/.
    /// Any record that doesn't parse, or a repeated UUID, makes the whole log unreadable.
    static func createdPartitions(log: Data) -> [RemovalCreatedPartition]? {
      let marker = "New partition: Partition("
      guard
        let pattern = try? NSRegularExpression(
          pattern:
            #"^name='[^']*', offset=[0-9]+, size=[0-9]+, free=False, type='([^']+)', uuid='([0-9A-Fa-f-]{36})'"#
        )
      else { return nil }
      var created = [RemovalCreatedPartition]()
      for line in String(decoding: log, as: UTF8.self).split(whereSeparator: \.isNewline) {
        guard let range = line.range(of: marker) else { continue }
        let rest = String(line[range.upperBound...])
        let whole = NSRange(rest.startIndex..., in: rest)
        guard let match = pattern.firstMatch(in: rest, range: whole),
          let typeRange = Range(match.range(at: 1), in: rest),
          let uuidRange = Range(match.range(at: 2), in: rest),
          let uuid = UUID(uuidString: String(rest[uuidRange]))
        else { return nil }
        let entry = RemovalCreatedPartition(uuid: uuid.uuidString, type: String(rest[typeRange]))
        guard !created.contains(where: { $0.uuid == entry.uuid }) else { return nil }
        created.append(entry)
      }
      return created
    }

    /// The EFI partitions a startup container's m1n1 chainloads. Aurora's J700
    /// Stage 1 (the MacBook Neo) names its one ESP in a versioned, CRC-checked
    /// config block; asahi's m1n1 keeps variables after the first "STACKBOT" up
    /// to the first NUL, one per line (asahi-installer m1n1.py extract_vars).
    /// nil when neither is there.
    static func efiPartitions(bootObject: Data) -> [String]? {
      if let aurora = auroraStage1Partition(bootObject: bootObject) { return [aurora] }
      guard let marker = bootObject.range(of: Data("STACKBOT".utf8)) else { return nil }
      let tail = bootObject[marker.upperBound...]
      let region = tail.prefix { $0 != 0 }
      guard region.count < tail.count, region.allSatisfy({ $0 < 0x80 }) else { return nil }
      let key = "chosen.asahi,efi-system-partition="
      return String(decoding: region, as: UTF8.self).split(separator: "\n")
        .filter { $0.hasPrefix(key) }.map { String($0.dropFirst(key.count)) }
    }

    /// Aurora's J700 Stage 1 config block (aurora-silicon/m1n1
    /// tools/fill_stage1_config.py): magic, then version, proxy window, a
    /// NUL-padded 40-byte ESP PARTUUID and a 192-byte Stage 2 path, then the
    /// CRC-32 of those fields. nil unless there is exactly one valid version-1
    /// block naming an ESP.
    static func auroraStage1Partition(bootObject: Data) -> String? {
      let magic = Data("AURORA-S1-CFG01\0".utf8)
      let bodySize = 4 + 4 + 40 + 192
      let bytes = [UInt8](bootObject)
      guard let first = bootObject.range(of: magic),
        bootObject.range(of: magic, in: first.upperBound..<bootObject.endIndex) == nil
      else { return nil }
      let start = first.upperBound - bootObject.startIndex
      guard start + bodySize + 4 <= bytes.count else { return nil }
      let body = Array(bytes[start..<(start + bodySize)])
      func word(_ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
      }
      guard word(start) == 1, word(start + bodySize) == crc32(body) else { return nil }
      let field = body[8..<48].prefix { $0 != 0 }
      guard body[(8 + field.count)..<48].allSatisfy({ $0 == 0 }),
        let uuid = UUID(uuidString: String(decoding: field, as: UTF8.self))
      else { return nil }
      return uuid.uuidString
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
      var crc: UInt32 = 0xFFFF_FFFF
      for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
      }
      return ~crc
    }
  }

  /// Every message says what was found and ends by saying nothing changed.
  enum RemovalText {
    static func size(_ bytes: UInt64) -> String {
      let value = Double(bytes)
      if value >= 1e12 { return String(format: "%.1f TB", value / 1e12) }
      if value >= 1e9 { return String(format: "%.1f GB", value / 1e9) }
      if value >= 1e6 { return String(format: "%.1f MB", value / 1e6) }
      return "\(bytes) bytes"
    }

    static func describe(_ part: RemovalPartition, _ snapshot: RemovalSnapshot) -> String {
      var facts = [String]()
      switch part.type {
      case "Apple_APFS": facts.append("APFS container")
      case "Apple_APFS_ISC": facts.append("Apple system container")
      case "Apple_APFS_Recovery": facts.append("Apple Recovery")
      case "EFI": facts.append("EFI partition")
      case "Linux Filesystem": facts.append("Linux partition")
      default: facts.append(part.type)
      }
      if !part.name.isEmpty { facts.append("“\(part.name)”") }
      facts.append(size(part.size))
      if part.type == "Apple_APFS",
        let container = snapshot.containers.first(where: { $0.storeUUID == part.uuid })
      {
        let order = ["System", "Data", "Preboot", "Recovery"]
        let volumes = container.volumes.sorted {
          let left = order.firstIndex(of: $0.roles.first ?? "") ?? order.count
          let right = order.firstIndex(of: $1.roles.first ?? "") ?? order.count
          return left == right ? $0.name < $1.name : left < right
        }
        facts.append(
          volumes.isEmpty
            ? "no volumes" : "volumes " + volumes.map { "“\($0.name)”" }.joined(separator: ", "))
      }
      return "\(part.identifier) (\(facts.joined(separator: ", ")))"
    }

    static func list(_ parts: [RemovalPartition], _ snapshot: RemovalSnapshot) -> String {
      parts.map { describe($0, snapshot) }.joined(separator: "; ")
    }

    static func refusal(
      _ finding: String, stranded: (bytes: UInt64, behind: [RemovalPartition])?,
      _ snapshot: RemovalSnapshot
    ) -> String {
      var message = finding
      if let stranded {
        let ids = stranded.behind.map(\.identifier).joined(separator: ", ")
        message +=
          " \(size(stranded.bytes)) of unallocated space isn’t directly after macOS: \(ids) \(stranded.behind.count == 1 ? "sits" : "sit") between them, so macOS can’t grow into it."
      }
      return message + " Nothing was changed."
    }

    static func inconsistent(_ parts: [RemovalPartition], _ snapshot: RemovalSnapshot) -> String {
      "The internal disk’s partition map couldn’t be read consistently. Found: \(list(parts, snapshot)). Nothing was changed."
    }

    static func unexpectedFrame(_ parts: [RemovalPartition], _ snapshot: RemovalSnapshot)
      -> String
    {
      "The internal disk doesn’t have the layout removal expects: Apple’s system container first, the running macOS next and Apple Recovery last. Found: \(list(parts, snapshot)). Nothing was changed."
    }

    static func nothingFound(gap: UInt64) -> String {
      if gap == 0 {
        return
          "No Omarchy installation, or other installation made with the Asahi installer, was found, and there’s no unallocated space after macOS. Nothing was changed."
      }
      return
        "No Omarchy installation, or other installation made with the Asahi installer, was found. \(size(gap)) directly after macOS is unallocated; that’s too little to return, so it was left as it is. Nothing was changed."
    }

    static func otherSystem(_ parts: [RemovalPartition], _ snapshot: RemovalSnapshot) -> String {
      "Found another system: \(list(parts, snapshot)). It looks like another macOS installation, and removal never deletes one."
    }

    static func foreign(_ parts: [RemovalPartition], _ snapshot: RemovalSnapshot) -> String {
      "Found \(parts.count == 1 ? "a partition that isn’t" : "partitions that aren’t") part of an installation made with the Asahi installer: \(list(parts, snapshot)). Removal only deletes partitions it can prove belong to one installation, so it stopped."
    }

    static func several(_ parts: [RemovalPartition], _ snapshot: RemovalSnapshot) -> String {
      "Found more than one installation: \(list(parts, snapshot)). Removal handles a single installation, so it stopped."
    }

    static func partial(_ parts: [RemovalPartition], _ snapshot: RemovalSnapshot) -> String {
      "Found \(list(parts, snapshot)) without the startup container every installation made with the Asahi installer has. This looks like a partly removed installation, which needs a manual review."
    }

    static func shape(_ parts: [RemovalPartition], _ snapshot: RemovalSnapshot) -> String {
      "Found a startup container, but the partitions with it don’t match one installation (startup container, EFI partition, then up to two Linux partitions, side by side): \(list(parts, snapshot))."
    }

    static func members(_ installation: RemovalInstallation) -> String {
      installation.members.map(\.identifier).joined(separator: ", ")
    }

    static func unconfirmed(_ installation: RemovalInstallation, reason: String) -> String {
      "Found the installation “\(installation.name)” (\(members(installation))), but \(reason). It can’t be confirmed as one installation, so nothing was changed."
    }

    static func unreadable(_ installation: RemovalInstallation, detail: String) -> String {
      "Found the installation “\(installation.name)” (\(members(installation))), but its files couldn’t be checked: \(detail) Nothing was changed."
    }

    static func growthLimited(free: UInt64, limit: UInt64) -> String {
      "\(size(free)) directly after macOS is unallocated, but macOS reports it can only grow to \(size(limit)). Nothing was changed."
    }

    /// The plan line's detail: what the Mac starts up from before removal.
    static func startupNow(_ startup: RemovalStartup) -> String {
      switch startup {
      case .macOS: return "It already starts up from macOS"
      case .other(let name): return "Your Mac starts up from “\(name)” now"
      case .nextStartupOverride: return "Replaces a one-time startup choice for the next restart"
      case .unknown: return "macOS couldn’t report which system your Mac starts up from"
      }
    }

    static let startupChanged =
      "Your Mac’s startup disk changed since you reviewed removal. Close this window and review removal again."

    static func startupRefused(_ name: String, reason: String?) -> String {
      "macOS didn’t set “\(name)” as the startup disk\(reported(reason)). Nothing was deleted."
    }

    /// After macOS accepted the change, so the startup disk may now be macOS.
    static func startupUnconfirmed(_ name: String, _ now: RemovalStartup, reason: String?)
      -> String
    {
      let state: String
      switch now {
      case .macOS: state = "your Mac starts up from macOS"
      case .other(let other): state = "your Mac starts up from “\(other)”"
      case .nextStartupOverride:
        state = "a one-time startup choice for the next restart is still set"
      case .unknown: state = "it can’t tell which system your Mac starts up from"
      }
      let failed = reason == nil ? "" : ", and replacing it didn’t work\(reported(reason))"
      return
        "macOS set “\(name)” as the startup disk, but afterwards it reports that \(state)\(failed). Nothing was deleted."
    }

    private static func reported(_ reason: String?) -> String {
      guard let reason, !reason.isEmpty else { return "" }
      return ". It reported: “\(reason)”"
    }
  }
#endif
