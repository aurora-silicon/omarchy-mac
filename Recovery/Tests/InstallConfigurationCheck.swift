import Foundation

@main struct InstallConfigurationCheck {
  static func main() throws {
    let value: [String: Any] = [
      "schema": 2, "volumeName": "Omarchy Test", "bootstrap": NSNull(),
      "systemUUID": "11111111-1111-4111-8111-111111111111",
      "groupUUID": "22222222-2222-4222-8222-222222222222",
      "prebootUUID": "33333333-3333-4333-8333-333333333333",
      "espUUID": "44444444-4444-4444-8444-444444444444",
      "bootMode": "raw", "stage2Path": "m1n1/boot.bin",
    ]
    let config = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: value))
    precondition(config.volumeName == "Omarchy Test" && config.bootMode == "raw")
    for (key, bad) in [
      ("schema", 1), ("schema", true), ("bootMode", "macho"),
      ("stage2Path", "../boot.bin"), ("systemUUID", "disk0s1"),
      ("espUUID", "00000000-0000-0000-0000-000000000000"),
      ("volumeName", "../macOS"), ("volumeName", "bad\nname"), ("volumeName", ""),
      ("unknown", "unused"),
    ] as [(String, Any)] {
      var changed = value
      changed[key] = bad
      do {
        _ = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: changed))
        preconditionFailure("accepted invalid \(key)")
      } catch {}
    }
    for key in value.keys {
      var changed = value
      changed.removeValue(forKey: key)
      do {
        _ = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: changed))
        preconditionFailure("accepted absent \(key)")
      } catch {}
    }
    var bootstrapped = value
    bootstrapped["bootstrap"] =
      [
        "mode": "source-volume-owner",
        "sourceSystemUUID": "55555555-5555-4555-8555-555555555555",
        "sourceGroupUUID": "66666666-6666-4666-8666-666666666666",
        "ownerUUIDs": ["77777777-7777-4777-8777-777777777777"],
      ] as [String: Any]
    _ = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: bootstrapped))
    for key in ["mode", "ownerUUIDs", "sourceSystemUUID", "sourceGroupUUID"] {
      var changed = bootstrapped
      var bootstrap = changed["bootstrap"] as! [String: Any]
      bootstrap[key] = "invalid"
      changed["bootstrap"] = bootstrap
      do {
        _ = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: changed))
        preconditionFailure("accepted invalid bootstrap \(key)")
      } catch {}
    }
    print("PASS strict per-install configuration, raw-only mode, IDs, paths and missing fields")
  }
}
