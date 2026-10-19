#if os(macOS)
  import CryptoKit
  import Darwin
  import Foundation
  import RecoveryAccountCore

  /// Recognizes the closed legacy handoff installed by the pinned runtime.
  /// It never executes the launcher or grants native account operations.
  struct LegacyRecoveryHandoff: Sendable {
    private let launcherDigest: String

    init() {
      launcherDigest = "a160bd8c5c98c42943190c06b5c3f8b12ef35dd4bcb2015de53e0c2942fe6a39"
    }

    init(authenticatedLauncherDigest: String) {
      launcherDigest = authenticatedLauncherDigest
    }

    func fingerprint(
      system: URL, group: String,
      read: ((URL, Int) throws -> Data)? = nil
    ) throws -> String? {
      // A damaged or interrupted native installation must never downgrade.
      for name in [InstallerProductIdentity.recoveryAppBundleName, "Aurora/Recovery"] {
        var info = stat()
        if lstat(system.appendingPathComponent(name).path, &info) == 0 { return nil }
        guard errno == ENOENT else {
          throw AccountSetupFailure("The Recovery handoff could not be inspected.")
        }
      }
      let app = "Finish Installation.app/Contents/"
      let limits = [
        ".IAPhysicalMedia": 65536,
        app + "Info.plist": 65536,
        app + "MacOS/step2_launcher.sh": 65536,
        app + "Resources/step2.sh": 65536,
        app + "Resources/boot.bin": 16 << 20,
      ]
      var files = [String: Data]()
      for (name, maximum) in limits {
        if let read {
          files[name] = try read(system.appendingPathComponent(name), maximum)
        } else {
          try Self.requireProtectedParents(system: system, relativePath: name)
          files[name] = try RecoveryAccountInstaller.protectedRead(
            system.appendingPathComponent(name), limit: maximum)
        }
      }
      guard
        let infoBytes = files[app + "Info.plist"],
        let info = try PropertyListSerialization.propertyList(from: infoBytes, format: nil)
          as? [String: Any],
        info["CFBundleExecutable"] as? String == "step2_launcher.sh",
        let marker = files[".IAPhysicalMedia"],
        (try PropertyListSerialization.propertyList(from: marker, format: nil)) is [String: Any],
        let launcher = files[app + "MacOS/step2_launcher.sh"],
        Self.digest(launcher) == launcherDigest,
        let scriptBytes = files[app + "Resources/step2.sh"],
        let script = String(data: scriptBytes, encoding: .utf8),
        script.hasPrefix("#!"),
        script.split(separator: "\n").filter({ $0.hasPrefix("VGID=") }).map(String.init)
          == ["VGID=\"\(group)\""],
        let boot = files[app + "Resources/boot.bin"], !boot.isEmpty
      else { throw AccountSetupFailure("The legacy Recovery handoff is incomplete or changed.") }
      // Bind all admitted bytes to the expiring ticket. A later edit invalidates
      // rediscovery even when its volume UUIDs remain unchanged.
      let identities = files.mapValues(Self.digest)
      return Self.digest(try JSONSerialization.data(withJSONObject: identities, options: .sortedKeys))
    }

    private static func digest(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func requireProtectedParents(
      system: URL, relativePath: String, expectedOwnerID: uid_t = 0
    ) throws {
      var path = system
      let components = relativePath.split(separator: "/").dropLast()
      for component in [""] + components.map(String.init) {
        if !component.isEmpty { path.appendPathComponent(component) }
        var info = stat()
        // APFS mount roots normally permit their administrative group to write;
        // every directory inside the legacy app must be root-controlled.
        let writeMask: mode_t = component.isEmpty ? 0o002 : 0o022
        guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == expectedOwnerID, info.st_mode & writeMask == 0
        else { throw AccountSetupFailure("The legacy Recovery path is unsuitable.") }
      }
    }
  }
#endif
