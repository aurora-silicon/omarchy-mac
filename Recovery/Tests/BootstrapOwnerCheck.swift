import Foundation

@main struct BootstrapOwnerCheck {
  static func main() throws {
    let first = "11111111-1111-4111-8111-111111111111"
    let second = "22222222-2222-4222-8222-222222222222"
    let sourceID = "33333333-3333-4333-8333-333333333333"
    let sourceGroup = "44444444-4444-4444-8444-444444444444"
    let bootstrap = BootstrapAuthorization(
      mode: "source-volume-owner", sourceSystemUUID: sourceID,
      sourceGroupUUID: sourceGroup, ownerUUIDs: [first, second])
    let admins: [String: Any] = ["source-owner": ["GeneratedUID": first]]
    let sourceInfo: [String: Any] = ["VolumeUUID": sourceID, "APFSVolumeGroupID": sourceGroup]
    func users(_ ids: [String]) -> [String: Any] {
      ["Users": ids.map { ["APFSCryptoUserUUID": $0, "VolumeOwner": true] }]
    }
    let result = try RecoveryOwnerResolver.resolve(
      admins: admins, targetUsers: users([]), bootstrap: bootstrap,
      source: { (sourceInfo, users([first])) })
    precondition(result.username == "source-owner" && result.uuid == UUID(uuidString: first))
    let actualTarget = try RecoveryOwnerResolver.resolve(
      admins: admins, targetUsers: users([first]), bootstrap: bootstrap,
      source: { fatalError("target owner must not query source") })
    precondition(result == actualTarget)
    func refused(_ work: () throws -> RecoveryOwner) {
      do {
        _ = try work()
        fatalError("unexpected owner authorization")
      } catch {}
    }
    refused {
      try RecoveryOwnerResolver.resolve(
        admins: ["forged": ["GeneratedUID": second]], targetUsers: users([]), bootstrap: bootstrap,
        source: { (sourceInfo, users([first])) })
    }
    refused {
      try RecoveryOwnerResolver.resolve(
        admins: admins, targetUsers: users([]), bootstrap: bootstrap,
        source: { throw RecoveryOwnerError.noOwner })
    }
    refused {
      try RecoveryOwnerResolver.resolve(
        admins: admins, targetUsers: users([]), bootstrap: bootstrap,
        source: { (["VolumeUUID": second, "APFSVolumeGroupID": sourceGroup], users([first])) })
    }
    refused {
      try RecoveryOwnerResolver.resolve(
        admins: admins, targetUsers: users([]), bootstrap: bootstrap,
        source: { (["VolumeUUID": sourceID, "APFSVolumeGroupID": second], users([first])) })
    }
    refused {
      try RecoveryOwnerResolver.resolve(
        admins: ["one": ["GeneratedUID": first], "two": ["GeneratedUID": second]],
        targetUsers: users([]), bootstrap: bootstrap,
        source: { (sourceInfo, users([first, second])) })
    }
    refused {
      try RecoveryOwnerResolver.resolve(
        admins: admins, targetUsers: users([]), bootstrap: nil,
        source: { fatalError("implicit source fallback must not run") })
    }
    let unregistered = BootstrapAuthorization(
      mode: "source-volume-owner", sourceSystemUUID: sourceID,
      sourceGroupUUID: sourceGroup, ownerUUIDs: [second])
    refused {
      try RecoveryOwnerResolver.resolve(
        admins: admins, targetUsers: users([]), bootstrap: unregistered,
        source: { (sourceInfo, users([first])) })
    }
    print(
      "PASS explicit bootstrap, target precedence, forged/missing/changed/ambiguous source rejection"
    )
  }
}
