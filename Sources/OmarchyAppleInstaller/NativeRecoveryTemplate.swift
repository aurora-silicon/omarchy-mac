#if os(macOS)
  import CryptoKit
  import Darwin
  import Foundation

  enum NativeRecoveryTemplateError: Error, Equatable {
    case unavailable
    case unsafeTemplate
    case invalidIdentity
  }

  struct PreparedNativeRecoveryTemplate: Sendable {
    let directory: URL
    let app: URL
    let manifest: URL
    let requirement: String

    var environment: [String: String] {
      [
        "OMARCHY_RECOVERY_APP": app.path,
        "OMARCHY_RECOVERY_MANIFEST": manifest.path,
        "OMARCHY_RECOVERY_REQUIREMENT": requirement,
      ]
    }

    func remove() {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  /// A per-job snapshot of the helper's own signed enrollment app. No source
  /// path, identity or inventory is accepted from the GUI or distro payload.
  enum NativeRecoveryTemplate {
    private struct FileIdentity: Codable, Equatable {
      let sha256: String
      let bytes: Int
    }

    private struct Inventory: Encodable, Equatable {
      let schema = 1
      let buildMode = "recovery"
      let files: [String: FileIdentity]
    }

    static let archiveFileName = "native-recovery.json"
    static let maximumArchiveBytes: UInt64 = 64 << 20

    static func bundledURL() -> URL {
      Bundle.main.bundleURL.appendingPathComponent(
        "Contents/Resources/RecoveryTemplate/" + InstallerProductIdentity.recoveryAppBundleName)
    }

    // This flat, bounded data container has no links, executable extraction
    // rules or archive paths. Only the reconstructed app's signature authorizes it.
    static func archiveData(from app: URL) throws -> Data {
      let recorded = try inventory(app, owner: nil)
      var files = [String: Data]()
      for (name, identity) in recorded.files {
        let bytes = try Data(contentsOf: app.appendingPathComponent(name))
        guard bytes.count == identity.bytes,
          SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == identity.sha256
        else { throw NativeRecoveryTemplateError.unsafeTemplate }
        files[name] = bytes
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(files)
      guard UInt64(data.count) <= maximumArchiveBytes else { throw NativeRecoveryTemplateError.unsafeTemplate }
      return data
    }

    static func prepare(package: ImportedEngineHandoffPackage) throws -> PreparedNativeRecoveryTemplate {
      guard let archive = package.recoveryTemplateURL,
        let requirement = requirement(environment: ProcessInfo.processInfo.environment)
      else { throw NativeRecoveryTemplateError.unavailable }
      let prepared = try prepare(
        archive: archive, in: package.packageURL.deletingLastPathComponent(),
        owner: 0, requirement: requirement
      ) { app in try verify(app, requirement: requirement) }
      do {
        try publish(prepared)
        return prepared
      } catch {
        prepared.remove()
        throw error
      }
    }

    static func prepare(
      archive: URL, in parent: URL, owner: uid_t, requirement: String,
      verify: (URL) throws -> Void
    ) throws -> PreparedNativeRecoveryTemplate {
      try requireSafe(archive, directory: false, owner: owner)
      try requireSafe(parent, directory: true, owner: owner)
      let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size > 0, UInt64(size) <= maximumArchiveBytes else { throw NativeRecoveryTemplateError.unsafeTemplate }
      let files = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: archive))
      guard !files.isEmpty, files.count <= 10_000 else { throw NativeRecoveryTemplateError.unsafeTemplate }
      var total = 0
      for (name, data) in files {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard name.utf8.count <= 1024, components.first == "Contents",
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }),
          data.count <= 64 << 20
        else { throw NativeRecoveryTemplateError.unsafeTemplate }
        total += data.count
        guard total <= 128 << 20 else { throw NativeRecoveryTemplateError.unsafeTemplate }
      }
      let directory = parent.appendingPathComponent("native-recovery-\(UUID().uuidString.lowercased())")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let result = PreparedNativeRecoveryTemplate(
        directory: directory, app: directory.appendingPathComponent(InstallerProductIdentity.recoveryAppBundleName),
        manifest: directory.appendingPathComponent("omarchy-recovery-app.json"), requirement: requirement)
      do {
        for (name, data) in files {
          let path = result.app.appendingPathComponent(name)
          try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
          try data.write(to: path, options: .withoutOverwriting)
          let mode = name == "Contents/MacOS/OmarchyRecovery" ? 0o700 : 0o400
          try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path.path)
        }
        let recorded = try inventory(result.app, owner: owner)
        try verify(result.app)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(recorded).write(to: result.manifest, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: result.manifest.path)
        return result
      } catch {
        result.remove()
        throw error
      }
    }

    private static func verify(_ app: URL, requirement: String) throws {
      _ = try AccountNativeCommand.checked(
        "/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=" + requirement, app.path])
    }

    private static func publish(_ prepared: PreparedNativeRecoveryTemplate) throws {
      let destination = URL(fileURLWithPath: InstallerProductIdentity.installedRecoveryTemplateDirectory)
      let parent = destination.deletingLastPathComponent()
      try requireSafe(parent, directory: true, owner: 0)
      let staged = parent.appendingPathComponent(".native-recovery-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: staged) }
      let app = staged.appendingPathComponent(InstallerProductIdentity.recoveryAppBundleName)
      try FileManager.default.copyItem(at: prepared.app, to: app)
      _ = try inventory(app, owner: 0)
      try verify(app, requirement: prepared.requirement)
      if FileManager.default.fileExists(atPath: destination.path) {
        try requireSafe(destination, directory: true, owner: 0)
        guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
          throw NativeRecoveryTemplateError.unsafeTemplate
        }
      } else {
        try FileManager.default.moveItem(at: staged, to: destination)
      }
    }

    static func prepare(
      source: URL, in parent: URL, owner: uid_t, requirement: String,
      verify: (URL) throws -> Void
    ) throws -> PreparedNativeRecoveryTemplate {
      try requireSafe(parent, directory: true, owner: owner)
      let original = try inventory(source, owner: owner)
      try verify(source)
      let directory = parent.appendingPathComponent("native-recovery-\(UUID().uuidString.lowercased())")
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let prepared = PreparedNativeRecoveryTemplate(
        directory: directory,
        app: directory.appendingPathComponent(InstallerProductIdentity.recoveryAppBundleName),
        manifest: directory.appendingPathComponent("omarchy-recovery-app.json"), requirement: requirement)
      do {
        try FileManager.default.copyItem(at: source, to: prepared.app)
        let copied = try inventory(prepared.app, owner: owner)
        guard copied == original else { throw NativeRecoveryTemplateError.unsafeTemplate }
        try verify(prepared.app)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(copied).write(to: prepared.manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: prepared.manifest.path)
        return prepared
      } catch {
        prepared.remove()
        throw error
      }
    }

    static func requirement(environment: [String: String]) -> String? {
      if let pinned = environment["OMARCHY_RECOVERY_TEMPLATE_REQUIREMENT"] {
        return pinned.range(of: "\\Acdhash H\"[0-9a-f]{40}(?:[0-9a-f]{24})?\"\\z", options: .regularExpression) != nil ? pinned : nil
      }
      guard let client = environment[InstallerProductIdentity.clientRequirementEnvironmentVariable],
        let team = RestoreImageHelper.teamIdentifier(inClientRequirement: client)
      else { return nil }
      return "anchor apple generic and identifier \"org.aurorasilicon.omarchy.recovery.recovery\""
        + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    private static func requireSafe(_ url: URL, directory: Bool, owner: uid_t?) throws {
      var status = stat()
      guard lstat(url.path, &status) == 0,
        (owner == nil || status.st_uid == owner), status.st_mode & 0o022 == 0,
        status.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG)
      else { throw NativeRecoveryTemplateError.unsafeTemplate }
    }

    private static func inventory(_ app: URL, owner: uid_t?) throws -> Inventory {
      try requireSafe(app, directory: true, owner: owner)
      var failure: Error?
      guard let enumerator = FileManager.default.enumerator(
        at: app, includingPropertiesForKeys: nil,
        errorHandler: { _, error in failure = error; return false })
      else { throw NativeRecoveryTemplateError.unsafeTemplate }
      var files = [String: FileIdentity]()
      var total = 0
      var entries = 0
      for case let path as URL in enumerator {
        entries += 1
        var status = stat()
        guard entries <= 10_000, lstat(path.path, &status) == 0 else {
          throw NativeRecoveryTemplateError.unsafeTemplate
        }
        if status.st_mode & S_IFMT == S_IFDIR {
          try requireSafe(path, directory: true, owner: owner)
          continue
        }
        try requireSafe(path, directory: false, owner: owner)
        guard status.st_size >= 0, status.st_size <= 64 << 20 else {
          throw NativeRecoveryTemplateError.unsafeTemplate
        }
        total += Int(status.st_size)
        guard total <= 128 << 20 else { throw NativeRecoveryTemplateError.unsafeTemplate }
        let data = try Data(contentsOf: path)
        guard data.count == Int(status.st_size) else { throw NativeRecoveryTemplateError.unsafeTemplate }
        let relative = String(path.path.dropFirst(app.path.count + 1))
        files[relative] = FileIdentity(
          sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: data.count)
      }
      if let failure { throw failure }
      guard !files.keys.contains(where: {
        $0 == "Contents/Resources/install-config.json" || $0.hasPrefix("Contents/Resources/AuraPayloads/")
      }) else { throw NativeRecoveryTemplateError.unsafeTemplate }
      let info = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil)
        as? [String: Any]
      let executable = app.appendingPathComponent("Contents/MacOS/OmarchyRecovery")
      var status = stat()
      guard info?["OmarchyRecoveryBuildMode"] as? String == "recovery",
        info?["OmarchyRecoveryDataLayout"] as? String == "external-install-data-v1",
        info?["CFBundleExecutable"] as? String == "OmarchyRecovery",
        info?["CFBundleDisplayName"] as? String == InstallerProductIdentity.appName,
        lstat(executable.path, &status) == 0, status.st_mode & 0o111 != 0,
        files["Contents/MacOS/OmarchyRecovery"] != nil
      else { throw NativeRecoveryTemplateError.invalidIdentity }
      return Inventory(files: files)
    }
  }
#endif
