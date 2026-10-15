import Foundation

enum InstallConfigurationError: Error, LocalizedError {
  case invalid
  var errorDescription: String? {
    "This installer is missing valid configuration for its target volume. Run the first installation step again."
  }
}

struct InstallConfiguration: Decodable {
  let schema: Int
  let volumeName: String
  let systemUUID: String
  let groupUUID: String
  let prebootUUID: String
  let espUUID: String
  let bootMode: String
  let stage2Path: String
  let bootstrap: BootstrapAuthorization?

  static func decode(_ data: Data) throws -> InstallConfiguration {
    let keys: Set<String> = [
      "schema", "volumeName", "systemUUID", "groupUUID", "prebootUUID", "espUUID",
      "bootMode", "stage2Path", "bootstrap",
    ]
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == keys
    else { throw InstallConfigurationError.invalid }
    let config = try JSONDecoder().decode(Self.self, from: data)
    guard config.schema == 2, config.bootMode == "raw", config.stage2Path == "m1n1/boot.bin",
      !config.volumeName.isEmpty, config.volumeName.count <= 80,
      !config.volumeName.contains("/"),
      config.volumeName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else { throw InstallConfigurationError.invalid }
    for identifier in [config.systemUUID, config.groupUUID, config.prebootUUID, config.espUUID] {
      guard let uuid = UUID(uuidString: identifier), uuid.uuidString == identifier,
        identifier != "00000000-0000-0000-0000-000000000000"
      else { throw InstallConfigurationError.invalid }
    }
    if let bootstrap = config.bootstrap {
      guard let values = object["bootstrap"] as? [String: Any],
        Set(values.keys) == ["mode", "sourceSystemUUID", "sourceGroupUUID", "ownerUUIDs"],
        bootstrap.sourceGroupUUID != config.groupUUID,
        bootstrap.sourceSystemUUID != config.systemUUID
      else { throw InstallConfigurationError.invalid }
      try bootstrap.validate()
    }
    return config
  }
}
