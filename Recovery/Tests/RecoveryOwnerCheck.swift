import Foundation

@main struct Check {
  static func main() throws {
    let oldID = "FCFB180D-E7C9-4F34-8310-D6CA45321B5B"
    let ownerID = "65EB51D3-2203-4A35-9FC1-3FE8D9DF816A"
    let admins: [String: Any] = [
      "dj": ["GeneratedUID": oldID], "aurora-owner": ["GeneratedUID": ownerID],
    ]
    let users: [String: Any] = [
      "Users": [
        ["APFSCryptoUserUUID": ownerID.lowercased(), "VolumeOwner": true],
        ["APFSCryptoUserUUID": oldID, "VolumeOwner": false],
      ]
    ]
    let owner = try RecoveryOwnerResolver.resolve(admins: admins, cryptoUsers: users)
    precondition(owner.username == "aurora-owner" && owner.uuid == UUID(uuidString: ownerID))
    do {
      _ = try RecoveryOwnerResolver.resolve(
        admins: ["dj": ["GeneratedUID": oldID]], cryptoUsers: users)
      fatalError("stale admin must not fall back to dj")
    } catch RecoveryOwnerError.noOwner {}
    do {
      _ = try RecoveryOwnerResolver.resolve(
        admins: admins,
        cryptoUsers: [
          "Users": [
            ["APFSCryptoUserUUID": ownerID, "VolumeOwner": true],
            ["APFSCryptoUserUUID": oldID, "VolumeOwner": true],
          ]
        ])
      fatalError("must not choose the first of multiple owners")
    } catch RecoveryOwnerError.ambiguous {}
    for invalid in [
      [String: Any](), ["aurora-owner": ["GeneratedUID": "invalid"]],
      ["bad\nname": ["GeneratedUID": ownerID]],
    ] {
      do {
        _ = try RecoveryOwnerResolver.resolve(admins: invalid, cryptoUsers: users)
        fatalError("invalid metadata")
      } catch RecoveryOwnerError.noOwner {}
    }
    try RecoveryOwnerResolver.verify(owner, current: owner)
    do {
      try RecoveryOwnerResolver.verify(
        owner, current: RecoveryOwner(username: "changed", uuid: owner.uuid))
      fatalError("owner changed after password prompt")
    } catch RecoveryOwnerError.changed {}
    print(
      "PASS target owner mapping; stale/foreign/non-owner rejection; ambiguous owner rejection; metadata validation; owner-change check"
    )
  }
}
