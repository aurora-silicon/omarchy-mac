import Foundation

struct RecoveryOwner: Equatable {
  let username: String
  let uuid: UUID
}

struct BootstrapAuthorization: Decodable {
  let mode: String
  let sourceSystemUUID: String
  let sourceGroupUUID: String
  let ownerUUIDs: [String]

  func validate() throws {
    guard mode == "source-volume-owner", !ownerUUIDs.isEmpty, ownerUUIDs.count <= 32,
      Set(ownerUUIDs).count == ownerUUIDs.count
    else { throw RecoveryOwnerError.noOwner }
    for raw in [sourceSystemUUID, sourceGroupUUID] + ownerUUIDs {
      guard let uuid = UUID(uuidString: raw), uuid.uuidString == raw,
        raw != "00000000-0000-0000-0000-000000000000"
      else { throw RecoveryOwnerError.noOwner }
    }
  }
}

enum RecoveryOwnerError: Error, LocalizedError {
  case noOwner, ambiguous, changed
  var errorDescription: String? {
    switch self {
    case .noOwner:
      return
        "Couldn’t identify a volume owner for this installation. Its Recovery user metadata may need repair."
    case .ambiguous:
      return
        "This installation has multiple eligible owners. Aurora could not determine which owner was selected in Recovery."
    case .changed: return "The volume owner changed. Continue again to authorize the current owner."
    }
  }
}

enum RecoveryOwnerResolver {
  static func isOwner(_ owner: RecoveryOwner, users: [String: Any]) -> Bool {
    (users["Users"] as? [[String: Any]] ?? []).contains {
      ($0["APFSCryptoUserUUID"] as? String).flatMap(UUID.init(uuidString:)) == owner.uuid
        && $0["VolumeOwner"] as? Bool == true
    }
  }
  // Preboot supplies account names; APFS supplies actual ownership. Never use
  // the host login, root, or a stale admin record as an implicit fallback.
  static func resolve(admins: [String: Any], cryptoUsers: [String: Any]) throws -> RecoveryOwner {
    let users = cryptoUsers["Users"] as? [[String: Any]] ?? []
    let owners = Set(
      users.compactMap { item -> UUID? in
        guard item["VolumeOwner"] as? Bool == true,
          let raw = item["APFSCryptoUserUUID"] as? String
        else { return nil }
        return UUID(uuidString: raw)
      })
    let candidates = admins.compactMap { name, value -> RecoveryOwner? in
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !name.contains("\0"), !name.contains("\n"), !name.contains("\r"),
        let entry = value as? [String: Any],
        let raw = entry["GeneratedUID"] as? String,
        let uuid = UUID(uuidString: raw), owners.contains(uuid)
      else { return nil }
      return RecoveryOwner(username: name, uuid: uuid)
    }
    guard !candidates.isEmpty else { throw RecoveryOwnerError.noOwner }
    guard candidates.count == 1 else { throw RecoveryOwnerError.ambiguous }
    return candidates[0]
  }
  static func verify(_ expected: RecoveryOwner, current: RecoveryOwner) throws {
    guard expected == current else { throw RecoveryOwnerError.changed }
  }

  // Asahi's initial stub has copied administrator metadata but no local APFS
  // users. Its existing macOS owner can authorize that bootstrap. Bind this
  // explicitly to the source recorded by stage 1, never to the Recovery login.
  static func resolve(
    admins: [String: Any], targetUsers: [String: Any], bootstrap: BootstrapAuthorization?,
    pendingAccount: RecoveryOwner? = nil,
    source: () throws -> (info: [String: Any], users: [String: Any], snapshots: Set<String>)
  ) throws -> RecoveryOwner {
    if let pendingAccount, isOwner(pendingAccount, users: targetUsers) {
      return pendingAccount
    }
    do {
      // Before Apple's final Startup Disk handoff, the newly created account
      // has no ownership. Initial enrollment uses only the explicitly bound
      // source owner; another target account must not silently replace it.
      if pendingAccount != nil { throw RecoveryOwnerError.noOwner }
      return try resolve(admins: admins, cryptoUsers: targetUsers)
    } catch RecoveryOwnerError.noOwner {
      guard let bootstrap else { throw RecoveryOwnerError.noOwner }
      try bootstrap.validate()
      let observed = try source()
      guard let actual = (observed.info["VolumeUUID"] as? String)?.uppercased(),
        UUID(uuidString: actual) != nil,
        actual == bootstrap.sourceSystemUUID
          || observed.snapshots.contains(bootstrap.sourceSystemUUID),
        (observed.info["APFSVolumeGroupID"] as? String)?.uppercased() == bootstrap.sourceGroupUUID
      else { throw RecoveryOwnerError.noOwner }
      let allowed = Set(bootstrap.ownerUUIDs)
      let users = (observed.users["Users"] as? [[String: Any]] ?? []).filter {
        guard let id = $0["APFSCryptoUserUUID"] as? String else { return false }
        return allowed.contains(id.uppercased())
      }
      return try resolve(admins: admins, cryptoUsers: ["Users": users])
    }
  }

  static func sourceSystem(
    group: String, candidates: [[String: Any]]
  ) throws -> [String: Any] {
    let matches = candidates.filter {
      ($0["APFSVolumeGroupID"] as? String)?.uppercased() == group
        && ($0["Roles"] as? [String] ?? []).contains("System")
    }
    guard matches.count == 1 else { throw RecoveryOwnerError.noOwner }
    return matches[0]
  }

  static func snapshotUUIDs(_ listing: [String: Any]) -> Set<String> {
    Set(
      (listing["Snapshots"] as? [[String: Any]] ?? []).compactMap {
        guard let raw = ($0["SnapshotUUID"] ?? $0["APFSSnapshotUUID"]) as? String,
          let uuid = UUID(uuidString: raw)
        else { return nil }
        return uuid.uuidString
      })
  }
}
