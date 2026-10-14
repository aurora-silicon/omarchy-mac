#if os(macOS)
  import Foundation

  public enum OmarchyRemovalKind: String, Codable, Equatable, Sendable {
    /// A startup container, its EFI partition and its Linux partitions.
    case installation
    /// No installation left; only unallocated space directly after macOS.
    case freeSpace
  }

  public struct OmarchyRemovalItem: Codable, Equatable, Sendable {
    public let title: String
    public let detail: String
    public let bytes: UInt64
    public init(title: String, detail: String, bytes: UInt64) {
      self.title = title
      self.detail = detail
      self.bytes = bytes
    }
  }

  /// The helper owns the disk plan. The client can only return this expiring ticket.
  public struct OmarchyRemovalTicket: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: OmarchyRemovalKind
    public let reclaimBytes: UInt64
    public let macOSBytesAfter: UInt64
    public let deletions: [OmarchyRemovalItem]
    public let kept: [OmarchyRemovalItem]
    public let notes: [String]
    /// Done before anything is deleted: macOS becomes the startup disk.
    public let startupDisk: OmarchyRemovalItem?
    public init(
      id: UUID, kind: OmarchyRemovalKind = .installation, reclaimBytes: UInt64,
      macOSBytesAfter: UInt64, deletions: [OmarchyRemovalItem] = [],
      kept: [OmarchyRemovalItem] = [], notes: [String] = [],
      startupDisk: OmarchyRemovalItem? = nil
    ) {
      self.id = id
      self.kind = kind
      self.reclaimBytes = reclaimBytes
      self.macOSBytesAfter = macOSBytesAfter
      self.deletions = deletions
      self.kept = kept
      self.notes = notes
      self.startupDisk = startupDisk
    }
    /// A helper older than the app sends tickets without the plan fields.
    public init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      id = try values.decode(UUID.self, forKey: .id)
      kind = try values.decodeIfPresent(OmarchyRemovalKind.self, forKey: .kind) ?? .installation
      reclaimBytes = try values.decode(UInt64.self, forKey: .reclaimBytes)
      macOSBytesAfter = try values.decode(UInt64.self, forKey: .macOSBytesAfter)
      deletions = try values.decodeIfPresent([OmarchyRemovalItem].self, forKey: .deletions) ?? []
      kept = try values.decodeIfPresent([OmarchyRemovalItem].self, forKey: .kept) ?? []
      notes = try values.decodeIfPresent([String].self, forKey: .notes) ?? []
      startupDisk = try values.decodeIfPresent(OmarchyRemovalItem.self, forKey: .startupDisk)
    }
    public var confirmation: String {
      kind == .freeSpace ? Self.freeSpaceConfirmation : Self.confirmation
    }
    public static let confirmation = "delete omarchy installation and data"
    public static let freeSpaceConfirmation = "return free space to macos"
  }

  public struct OmarchyRemovalReply: Codable, Sendable {
    public let ticket: OmarchyRemovalTicket?
    public let completed: Bool
    public let requiresReview: Bool
    public let message: String
    public init(
      ticket: OmarchyRemovalTicket? = nil, completed: Bool = false, requiresReview: Bool = false,
      message: String
    ) {
      self.ticket = ticket
      self.completed = completed
      self.requiresReview = requiresReview
      self.message = message
    }
  }

  /// What a kept helper's records say about a removal, for an app whose
  /// removal reply was lost. Only the helper can tell that a removal both
  /// completed and set aside the install journals of the installation it
  /// removed; the disk alone shows neither.
  public enum RemovalFinalization: String, Codable, Equatable, Sendable {
    /// Completed, and the earlier installation's journals are set aside:
    /// installing again is safe.
    case finalized
    /// The removal's record stops before it completed. Installing stays
    /// blocked until the record and the disk layout are checked.
    case unfinished
    /// Completed, but the earlier installation's journals couldn't be set
    /// aside yet. Each later request tries again; installing stays blocked
    /// until that works.
    case installRecordUncleared = "install-record-uncleared"
    /// The helper is running a job, perhaps still this removal.
    case busy
    /// No record of this removal, or the helper can't tell.
    case unknown
  }

  struct RemovalFailure: LocalizedError, Sendable {
    let message: String
    /// The message already says what changed, so nothing is appended to it.
    var complete = false
    var errorDescription: String? { message }
  }

  /// bless didn't make the change. `reason` is its last output line, with
  /// the password removed.
  struct RemovalStartupRefusal: Error, Sendable {
    let reason: String
  }

  struct RemovalPartition: Codable, Equatable, Sendable {
    let identifier: String
    let uuid: String
    let type: String
    let offset: UInt64
    var size: UInt64
    let name: String
    var end: UInt64 { offset + size }
    // BSD identifiers can change after deleting another partition. Identity cannot.
    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.uuid == rhs.uuid && lhs.type == rhs.type && lhs.offset == rhs.offset
        && lhs.size == rhs.size && lhs.name == rhs.name
    }
  }

  struct RemovalVolume: Codable, Equatable, Sendable {
    let uuid: String
    let name: String
    let roles: [String]
    let group: String?
    let identifier: String
    init(uuid: String, name: String, roles: [String], group: String? = nil, identifier: String = "")
    {
      self.uuid = uuid
      self.name = name
      self.roles = roles
      self.group = group
      self.identifier = identifier
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.uuid == rhs.uuid && lhs.name == rhs.name && lhs.roles == rhs.roles
        && lhs.group == rhs.group
    }
  }

  struct RemovalContainer: Codable, Equatable, Sendable {
    let uuid: String
    let storeUUID: String
    let volumes: [RemovalVolume]
  }

  struct RemovalSnapshot: Codable, Equatable, Sendable {
    let disk: String
    let devicePath: String
    let diskSize: UInt64
    let macOSStoreUUID: String
    let macOSContainerUUID: String
    var partitions: [RemovalPartition]
    var containers: [RemovalContainer]
  }

  /// One installation made by the Asahi installer engine: this app's own
  /// layout, older omarchy-mac installs and plain Asahi installs alike.
  struct RemovalInstallation: Codable, Equatable, Sendable {
    let name: String
    let stub: RemovalPartition
    let system: RemovalVolume
    let esp: RemovalPartition
    let linux: [RemovalPartition]
    var members: [RemovalPartition] { [stub, esp] + linux }

    /// The same partitions and volume with the BSD identifiers they have now.
    func live(in snapshot: RemovalSnapshot) -> RemovalInstallation? {
      func current(_ part: RemovalPartition) -> RemovalPartition? {
        snapshot.partitions.first { $0 == part }
      }
      guard let stub = current(stub), let esp = current(esp),
        let system = snapshot.containers.first(where: { $0.storeUUID == stub.uuid })?.volumes
          .first(where: { $0 == system })
      else { return nil }
      let linux = self.linux.compactMap(current)
      guard linux.count == self.linux.count else { return nil }
      return RemovalInstallation(name: name, stub: stub, system: system, esp: esp, linux: linux)
    }
  }

  enum RemovalStartup: Codable, Equatable, Sendable {
    case macOS
    case other(String)
    case nextStartupOverride
    case unknown
  }

  struct OmarchyRemovalPlan: Codable, Equatable, Sendable {
    let kind: OmarchyRemovalKind
    let snapshot: RemovalSnapshot
    let installation: RemovalInstallation?
    let evidence: RemovalEvidence?
    let members: [RemovalPartition]
    let macOS: RemovalPartition
    let targetMacOSBytes: UInt64
    /// What the Mac started up from at review when that wasn't the running
    /// macOS. Execution sets macOS as the startup disk before deleting.
    let startup: RemovalStartup?

    /// Read-only. Every check that can refuse happens here, before a ticket exists.
    init(disks: any RemovalDiskOperating) throws {
      let snapshot = try disks.snapshot()
      self.snapshot = snapshot
      switch try RemovalLayout.recognize(snapshot) {
      case .freeSpace(let macOS, let target):
        let limit = try disks.growLimit(macOS, disk: snapshot.disk)
        guard limit.addingReportingOverflow(1_048_576).partialValue >= target else {
          throw RemovalFailure(
            message: RemovalText.growthLimited(free: target - macOS.size, limit: limit))
        }
        kind = .freeSpace
        installation = nil
        evidence = nil
        members = []
        self.macOS = macOS
        targetMacOSBytes = target
        startup = nil
      case .installation(let found, let macOS, let target):
        let evidence: RemovalEvidence
        do { evidence = try disks.evidence(for: found, disk: snapshot.disk) } catch {
          let detail = (error as? RemovalFailure)?.message ?? "macOS couldn't read them"
          throw RemovalFailure(message: RemovalText.unreadable(found, detail: detail))
        }
        if let reason = evidence.problem(for: found) {
          throw RemovalFailure(message: RemovalText.unconfirmed(found, reason: reason))
        }
        let startup = try disks.startup(snapshot)
        kind = .installation
        installation = found
        self.evidence = evidence
        members = found.members
        self.macOS = macOS
        targetMacOSBytes = target
        self.startup = startup == .macOS ? nil : startup
      }
    }

    var reclaimBytes: UInt64 { targetMacOSBytes - macOS.size }

    var summary: String {
      if let installation {
        if startup != nil {
          return
            "Found “\(installation.name)”. Removal first sets macOS as the startup disk, then permanently deletes “\(installation.name)” and everything stored in it and returns its space to macOS."
        }
        return
          "Found “\(installation.name)”. Removal permanently deletes it and everything stored in it, then returns its space to macOS."
      }
      return
        "No installation was found, but \(RemovalText.size(reclaimBytes)) directly after macOS is unallocated. macOS can take it back. Nothing will be deleted."
    }

    func ticket(id: UUID) -> OmarchyRemovalTicket {
      let parts = snapshot.partitions.sorted { $0.offset < $1.offset }
      var deletions = [OmarchyRemovalItem]()
      var notes = [String]()
      if let installation {
        deletions.append(
          OmarchyRemovalItem(
            title: "Startup container “\(installation.name)”",
            detail: "\(installation.stub.identifier) · APFS", bytes: installation.stub.size))
        let espName = installation.esp.name.isEmpty ? "" : " “\(installation.esp.name)”"
        deletions.append(
          OmarchyRemovalItem(
            title: "EFI partition\(espName)", detail: installation.esp.identifier,
            bytes: installation.esp.size))
        for part in installation.linux {
          deletions.append(
            OmarchyRemovalItem(title: "Linux partition", detail: part.identifier, bytes: part.size))
        }
        if installation.linux.isEmpty {
          notes.append(
            "This installation has no Linux partitions of its own. If a Linux system elsewhere, for example on an external disk, starts through it, that system won’t start after removal. Its data isn’t touched."
          )
        }
      } else {
        notes.append(
          "macOS takes all the unallocated space directly after it, whatever put it there.")
      }
      let kept = [
        OmarchyRemovalItem(
          title: "macOS “\(macOSName)”",
          detail: "\(macOS.identifier) · grows to \(RemovalText.size(targetMacOSBytes))",
          bytes: macOS.size),
        OmarchyRemovalItem(
          title: "Apple system container", detail: parts[0].identifier, bytes: parts[0].size),
        OmarchyRemovalItem(
          title: "Apple Recovery", detail: parts[parts.count - 1].identifier,
          bytes: parts[parts.count - 1].size),
      ]
      return OmarchyRemovalTicket(
        id: id, kind: kind, reclaimBytes: reclaimBytes, macOSBytesAfter: targetMacOSBytes,
        deletions: deletions, kept: kept, notes: notes,
        startupDisk: startup.map {
          OmarchyRemovalItem(
            title: "Set macOS “\(macOSName)” as the startup disk",
            detail: RemovalText.startupNow($0), bytes: 0)
        })
    }

    var macOSName: String {
      snapshot.containers.first { $0.uuid == snapshot.macOSContainerUUID }?.volumes
        .first { $0.roles == ["System"] }?.name ?? "macOS"
    }

    /// Every intermediate state must be exactly the approved layout minus the
    /// partitions already removed. This also proves the gap is adjacent to macOS.
    func validate(_ current: RemovalSnapshot, removed: Set<String>, expanded: Bool = false) throws {
      guard current.disk == snapshot.disk, current.devicePath == snapshot.devicePath,
        current.diskSize == snapshot.diskSize, current.macOSStoreUUID == snapshot.macOSStoreUUID,
        current.macOSContainerUUID == snapshot.macOSContainerUUID
      else { throw RemovalFailure(message: "The disk identity changed. Removal stopped.") }
      var expected = snapshot.partitions.filter { !removed.contains($0.uuid) }
      if expanded {
        guard let actual = current.partitions.first(where: { $0.uuid == macOS.uuid }),
          actual.size > macOS.size, actual.size <= targetMacOSBytes,
          targetMacOSBytes - actual.size <= 1_048_576,
          let index = expected.firstIndex(where: { $0.uuid == macOS.uuid })
        else { throw RemovalFailure(message: "macOS did not reclaim the expected space.") }
        expected[index].size = actual.size
      }
      guard
        expected.sorted(by: { $0.offset < $1.offset })
          == current.partitions.sorted(by: { $0.offset < $1.offset }),
        snapshot.containers.filter({ !removed.contains($0.storeUUID) }).sorted(by: {
          $0.uuid < $1.uuid
        })
          == current.containers.sorted(by: { $0.uuid < $1.uuid })
      else {
        throw RemovalFailure(message: "The disk layout changed unexpectedly. Removal stopped.")
      }
    }

    func live(_ part: RemovalPartition, in current: RemovalSnapshot) throws -> RemovalPartition {
      guard let found = current.partitions.first(where: { $0 == part }) else {
        throw RemovalFailure(message: "The disk layout changed unexpectedly. Removal stopped.")
      }
      return found
    }
  }

  protocol RemovalDiskOperating: Sendable {
    func snapshot() throws -> RemovalSnapshot
    func evidence(for installation: RemovalInstallation, disk: String) throws -> RemovalEvidence
    func startup(_ snapshot: RemovalSnapshot) throws -> RemovalStartup
    /// Makes the running macOS the startup disk (`nextOnly`: for the next
    /// restart only), authorized by a local owner.
    func setMacOSStartup(
      _ snapshot: RemovalSnapshot, nextOnly: Bool, authorization: MachineOwnerAuthorization)
      throws
    func growLimit(_ macOS: RemovalPartition, disk: String) throws -> UInt64
    func deleteContainer(_ stub: RemovalPartition, disk: String) throws
    func erasePartition(_ partition: RemovalPartition, disk: String) throws
    func growContainer(_ macOS: RemovalPartition, disk: String) throws
  }

  struct OmarchyRemovalExecutor: Sendable {
    let disks: any RemovalDiskOperating

    func execute(
      _ plan: OmarchyRemovalPlan, authorization: MachineOwnerAuthorization? = nil,
      record: (String) throws -> Void
    ) throws {
      let first = try disks.snapshot()
      try plan.validate(first, removed: [])
      if let installation = plan.installation {
        // The ticket may be minutes old: the files that proved this is one
        // installation, and the startup choice, must still be exactly as approved.
        guard let live = installation.live(in: first),
          try disks.evidence(for: live, disk: first.disk) == plan.evidence
        else {
          throw RemovalFailure(
            message:
              "The installation changed since you reviewed it. Close this window and review removal again."
          )
        }
        let startup = try disks.startup(first)
        if startup != .macOS {
          guard let reviewed = plan.startup, startup == reviewed else {
            throw RemovalFailure(message: RemovalText.startupChanged)
          }
          guard let authorization else {
            throw RemovalFailure(
              message: "A macOS administrator account is needed to set the startup disk.")
          }
          try setMacOSStartup(plan, snapshot: first, authorization: authorization)
          var recorded = false
          do {
            try removeAndReturnSpace(plan) { phase in
              try record(phase)
              recorded = true
            }
          } catch let error where !recorded {
            let detail = (error as? RemovalFailure)?.message ?? error.localizedDescription
            throw RemovalFailure(
              message:
                "\(detail) Your Mac now starts up from macOS “\(plan.macOSName)”. Nothing was deleted.",
              complete: true)
          }
          return
        }
      }
      try removeAndReturnSpace(plan, record: record)
    }

    private func removeAndReturnSpace(
      _ plan: OmarchyRemovalPlan, record: (String) throws -> Void
    ) throws {
      var removed = Set<String>()
      // Delete the startup container first: if a volume is busy, diskutil refuses
      // before the Linux partitions are touched. No force-unmount or -force fallback.
      for (index, member) in plan.members.enumerated() {
        let current = try disks.snapshot()
        try plan.validate(current, removed: removed)
        let target = try plan.live(member, in: current)
        try record("removing-\(member.uuid)")
        if index == 0 {
          // Without a new name, current macOS deletes the physical store too.
          try disks.deleteContainer(target, disk: current.disk)
        } else {
          try disks.erasePartition(target, disk: current.disk)
        }
        removed.insert(member.uuid)
        try plan.validate(disks.snapshot(), removed: removed)
      }
      // With nothing deleted yet (free space only), a refused preflight must
      // not leave a journal behind that blocks later installs.
      if !plan.members.isEmpty { try record("returning-space-to-macos") }
      let current = try disks.snapshot()
      try plan.validate(current, removed: removed)
      let macOS = try plan.live(plan.macOS, in: current)
      let limit = try disks.growLimit(macOS, disk: current.disk)
      guard limit.addingReportingOverflow(1_048_576).partialValue >= plan.targetMacOSBytes else {
        throw RemovalFailure(
          message:
            "macOS reports it can only grow to \(RemovalText.size(limit)), not \(RemovalText.size(plan.targetMacOSBytes))."
        )
      }
      if plan.members.isEmpty { try record("returning-space-to-macos") }
      try disks.growContainer(macOS, disk: current.disk)
      try plan.validate(disks.snapshot(), removed: removed, expanded: true)
      try record("complete")
    }

    /// Nothing is deleted unless macOS then reports the running macOS as both
    /// the startup disk and the next restart's choice.
    private func setMacOSStartup(
      _ plan: OmarchyRemovalPlan, snapshot: RemovalSnapshot,
      authorization: MachineOwnerAuthorization
    ) throws {
      let name = plan.macOSName
      do {
        try disks.setMacOSStartup(snapshot, nextOnly: false, authorization: authorization)
      } catch let refusal as RemovalStartupRefusal {
        throw RemovalFailure(
          message: RemovalText.startupRefused(name, reason: refusal.reason), complete: true)
      }
      var now = try disks.startup(snapshot)
      if now == .nextStartupOverride {
        do {
          try disks.setMacOSStartup(snapshot, nextOnly: true, authorization: authorization)
        } catch {
          let reason = (error as? RemovalStartupRefusal)?.reason ?? error.localizedDescription
          throw RemovalFailure(
            message: RemovalText.startupUnconfirmed(name, now, reason: reason), complete: true)
        }
        now = try disks.startup(snapshot)
      }
      guard now == .macOS else {
        throw RemovalFailure(
          message: RemovalText.startupUnconfirmed(name, now, reason: nil), complete: true)
      }
    }
  }
#endif
