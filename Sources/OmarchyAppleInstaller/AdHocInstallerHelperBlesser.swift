#if os(macOS)
  import Foundation
  import Security

  /// Installs the bundled helper for builds signed ad hoc, which `SMJobBless`
  /// refuses. It does what `SMJobBless` would: copies the helper into
  /// `/Library/PrivilegedHelperTools`, owned by root, and registers its launchd
  /// job, through an administrator `do shell script`. Both the helper and the
  /// app it accepts are pinned to their exact code hashes, since an ad hoc
  /// identifier alone proves nothing.
  public struct AdHocInstallerHelperBlesser: InstallerHelperBlessing {
    private let bundle: URL
    private let label: String

    public init(
      bundle: URL = Bundle.main.bundleURL,
      label: String = InstallerProductIdentity.helperIdentifier
    ) {
      self.bundle = bundle
      self.label = label
    }

    /// Whether the app carries a helper and the daemon definition it needs.
    public static func isAvailable(
      in bundle: URL = Bundle.main.bundleURL,
      label: String = InstallerProductIdentity.helperIdentifier
    ) -> Bool {
      FileManager.default.isExecutableFile(atPath: helperURL(in: bundle, label: label).path)
        && FileManager.default.fileExists(atPath: daemonURL(in: bundle, label: label).path)
    }

    public func blessSilently(
      with authorization: MachineOwnerAuthorization,
      confirm: @escaping @Sendable () async -> Bool
    ) async -> InstallerHelperBlessResult {
      await bless(authorization, confirm: confirm)
    }

    public func blessWithDialog(
      confirm: @escaping @Sendable () async -> Bool
    ) async -> InstallerHelperBlessResult {
      await bless(nil, confirm: confirm)
    }

    private func bless(
      _ authorization: MachineOwnerAuthorization?,
      confirm: @escaping @Sendable () async -> Bool
    ) async -> InstallerHelperBlessResult {
      let command: String
      do {
        command = try shellCommand()
      } catch {
        return .failed("the bundled helper could not be verified")
      }
      guard await confirm() else {
        return .declined
      }
      return await Task.detached {
        Self.runAsAdministrator(command, authorization: authorization)
      }.value
    }

    func shellCommand() throws -> String {
      let helper = Self.helperURL(in: bundle, label: label)
      let helperRequirement =
        "identifier \"\(label)\" and cdhash H\"\(try Self.codeHash(at: helper))\""
      let data = try Data(contentsOf: Self.daemonURL(in: bundle, label: label))
      guard
        var plist = try PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: Any],
        var environment = plist["EnvironmentVariables"] as? [String: String],
        let client = environment[InstallerProductIdentity.clientRequirementEnvironmentVariable],
        !client.isEmpty
      else { throw CocoaError(.propertyListReadCorrupt) }
      environment[InstallerProductIdentity.clientRequirementEnvironmentVariable] =
        "\(client) and cdhash H\"\(try Self.codeHash(at: bundle))\""
      let installed = "/Library/PrivilegedHelperTools/" + label
      let daemon = "/Library/LaunchDaemons/\(label).plist"
      plist["EnvironmentVariables"] = environment
      plist["Program"] = installed
      plist.removeValue(forKey: "BundleProgram")
      let template = bundle.appendingPathComponent(
        "Contents/Resources/RecoveryTemplate/\(InstallerProductIdentity.recoveryAppBundleName)",
        isDirectory: true)
      let templateRequirement = "cdhash H\"\(try Self.codeHash(at: template))\""
      environment["OMARCHY_RECOVERY_TEMPLATE_REQUIREMENT"] = templateRequirement
      plist["EnvironmentVariables"] = environment
      let encoded = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0
      ).base64EncodedString()
      let templates = InstallerProductIdentity.installedRecoveryTemplateDirectory
      let quote = Self.shellQuote
      // Only this fixed text is elevated; the helper is verified again once it
      // is root-owned, before launchd can start it.
      return """
        set -eu
        umask 022
        /usr/bin/codesign --verify --strict -R=\(quote(helperRequirement)) \(quote(helper.path))
        /usr/bin/install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools
        staged=$(/usr/bin/mktemp /Library/PrivilegedHelperTools/.omarchy-helper.XXXXXX)
        new=\(quote(daemon + ".new"))
        recovery=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.omarchy-recovery.XXXXXX)
        trap '/bin/rm -f "$staged" "$new"; /bin/rm -rf "$recovery"' EXIT
        /usr/bin/install -o root -g wheel -m 0544 \(quote(helper.path)) "$staged"
        /usr/bin/codesign --verify --strict -R=\(quote(helperRequirement)) "$staged"
        /usr/bin/ditto \(quote(template.path)) "$recovery/\(InstallerProductIdentity.recoveryAppBundleName)"
        /usr/sbin/chown -R root:wheel "$recovery"
        /bin/chmod -R go-w "$recovery"
        /bin/chmod 0755 "$recovery"
        /usr/bin/codesign --verify --deep --strict -R=\(quote(templateRequirement)) "$recovery/\(InstallerProductIdentity.recoveryAppBundleName)"
        /usr/bin/printf '%s' \(quote(encoded)) | /usr/bin/base64 -D > "$new"
        /usr/sbin/chown root:wheel "$new"
        /bin/chmod 0644 "$new"
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        for _ in $(/usr/bin/seq 50); do
          /bin/launchctl print system/\(label) >/dev/null 2>&1 || break
          /bin/sleep 0.1
        done
        /bin/mv -f "$staged" \(quote(installed))
        /bin/rm -rf \(quote(templates))
        /bin/mv "$recovery" \(quote(templates))
        /bin/mv -f "$new" \(quote(daemon))
        trap - EXIT
        /bin/launchctl bootstrap system \(quote(daemon))
        """
    }

    private static func runAsAdministrator(
      _ command: String, authorization: MachineOwnerAuthorization?
    ) -> InstallerHelperBlessResult {
      // The script, and any password in it, goes in on standard input, never
      // in an argument other processes could read.
      var credentials = ""
      if let authorization {
        guard let password = String(data: authorization.password, encoding: .utf8) else {
          return .refused
        }
        credentials =
          " user name \(appleScriptString(authorization.username))"
          + " password \(appleScriptString(password))"
      }
      let script =
        "on run argv\ndo shell script (item 1 of argv)\(credentials) with administrator privileges\nend run\n"
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = ["-", command]
      let input = Pipe()
      let errors = Pipe()
      process.standardInput = input
      process.standardOutput = FileHandle.nullDevice
      process.standardError = errors
      do {
        try process.run()
      } catch {
        return .failed("osascript could not start")
      }
      input.fileHandleForWriting.write(Data(script.utf8))
      try? input.fileHandleForWriting.close()
      let output = errors.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        let detail = String(decoding: output, as: UTF8.self)
        if detail.contains("(-128)") { return .cancelled }
        if detail.contains("(-60005)") || detail.contains("(-60007)") { return .refused }
        return .failed("installing the helper failed: \(detail)")
      }
      return .blessed
    }

    static func appleScriptString(_ value: String) -> String {
      "\""
        + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func shellQuote(_ value: String) -> String {
      "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func helperURL(in bundle: URL, label: String) -> URL {
      bundle.appendingPathComponent("Contents/Library/LaunchServices/\(label)")
    }

    static func daemonURL(in bundle: URL, label: String) -> URL {
      bundle.appendingPathComponent("Contents/Library/LaunchDaemons/\(label).plist")
    }

    private static func codeHash(at url: URL) throws -> String {
      var code: SecStaticCode?
      guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
        let code,
        SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
          == errSecSuccess
      else { throw CocoaError(.fileReadCorruptFile) }
      var information: CFDictionary?
      guard
        SecCodeCopySigningInformation(
          code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
          == errSecSuccess,
        let information = information as? [String: Any],
        let digest = information[kSecCodeInfoUnique as String] as? Data
      else { throw CocoaError(.fileReadCorruptFile) }
      return digest.map { String(format: "%02x", $0) }.joined()
    }
  }
#endif
