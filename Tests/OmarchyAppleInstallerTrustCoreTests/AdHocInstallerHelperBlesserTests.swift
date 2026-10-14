#if os(macOS)
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class AdHocInstallerHelperBlesserTests: XCTestCase {
    func testAppleScriptStringsCannotEndEarly() {
      XCTAssertEqual(
        AdHocInstallerHelperBlesser.appleScriptString(#"pa"ss\word"#), #""pa\"ss\\word""#)
    }

    func testShellArgumentsCannotEndEarly() {
      XCTAssertEqual(AdHocInstallerHelperBlesser.shellQuote("it's"), #"'it'\''s'"#)
    }

    func testABundleWithoutAHelperCannotInstallOne() throws {
      let bundle = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".app")
      try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: bundle) }
      XCTAssertFalse(AdHocInstallerHelperBlesser.isAvailable(in: bundle))
      XCTAssertThrowsError(try AdHocInstallerHelperBlesser(bundle: bundle).shellCommand())
    }

    func testInstalledJobUsesExactSignedIdentitiesForBothEmbeddedModes() throws {
      for embedded in ["never", "identifier \"\(InstallerProductIdentity.appIdentifier)\""] {
        let fixture = try SignedFixture(client: embedded)
        defer { fixture.remove() }
        let command = try AdHocInstallerHelperBlesser(bundle: fixture.app).shellCommand()
        let plist = try fixture.installedPlist(command)
        let label = InstallerProductIdentity.helperIdentifier
        let variable = InstallerProductIdentity.clientRequirementEnvironmentVariable
        let appHash = try fixture.codeHash(fixture.app)
        let helperHash = try fixture.codeHash(fixture.helper)
        let expected =
          "identifier \"\(InstallerProductIdentity.appIdentifier)\" and cdhash H\"\(appHash)\""
        XCTAssertEqual(plist["EnvironmentVariables"] as? [String: String], [variable: expected])
        XCTAssertEqual(plist["Label"] as? String, label)
        XCTAssertEqual(plist["Program"] as? String, "/Library/PrivilegedHelperTools/\(label)")
        XCTAssertEqual(plist["MachServices"] as? [String: Bool], [label: true])
        XCTAssertEqual(plist["UserName"] as? String, "root")
        XCTAssertNil(plist["BundleProgram"])
        XCTAssertTrue(command.contains("identifier \"\(label)\" and cdhash H\"\(helperHash)\""))
        XCTAssertTrue(command.contains("$recovery/\(InstallerProductIdentity.recoveryAppName).app"))
        XCTAssertTrue(command.contains(InstallerProductIdentity.installedRecoveryTemplateDirectory))
        XCTAssertFalse(expected.contains("never"))
        let embeddedData = try Data(contentsOf: fixture.daemon)
        let original =
          try PropertyListSerialization.propertyList(from: embeddedData, format: nil)
          as! [String: Any]
        XCTAssertEqual(original["EnvironmentVariables"] as? [String: String], [variable: embedded])
      }
    }

    func testArbitraryEmbeddedPermissionsAreRefused() throws {
      for client in ["always", "identifier \"other.app\"", "never or always", ""] {
        let fixture = try SignedFixture(client: client)
        defer { fixture.remove() }
        XCTAssertThrowsError(try AdHocInstallerHelperBlesser(bundle: fixture.app).shellCommand())
      }
    }

    func testWrongSignedAppAndHelperIdentifiersAreRefused() throws {
      for wrongApp in [true, false] {
        let fixture = try SignedFixture(
          appIdentifier: wrongApp ? "other.app" : InstallerProductIdentity.appIdentifier,
          helperIdentifier: wrongApp ? InstallerProductIdentity.helperIdentifier : "other.helper")
        defer { fixture.remove() }
        XCTAssertThrowsError(try AdHocInstallerHelperBlesser(bundle: fixture.app).shellCommand())
      }
    }

    func testAnEmbeddedProgramOrExtraEnvironmentCannotBecomeRootPermissions() throws {
      for extra in ["Program", "EnvironmentVariables"] {
        let fixture = try SignedFixture(extra: extra)
        defer { fixture.remove() }
        XCTAssertThrowsError(try AdHocInstallerHelperBlesser(bundle: fixture.app).shellCommand())
      }
    }

    /// Only disposable copies of /usr/bin/true are signed. Neither the copies
    /// nor the generated registration shell command are ever executed.
    private final class SignedFixture {
      let root: URL
      let app: URL
      let helper: URL
      let daemon: URL

      init(
        client: String = "never", appIdentifier: String = InstallerProductIdentity.appIdentifier,
        helperIdentifier: String = InstallerProductIdentity.helperIdentifier, extra: String? = nil
      ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        app = root.appendingPathComponent("Fixture.app")
        let label = InstallerProductIdentity.helperIdentifier
        helper = AdHocInstallerHelperBlesser.helperURL(in: app, label: label)
        daemon = AdHocInstallerHelperBlesser.daemonURL(in: app, label: label)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
          try makeApp(app, identifier: appIdentifier)
          try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
          try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: helper)
          try sign(helper, identifier: helperIdentifier)
          let template = app.appendingPathComponent(
            "Contents/Resources/RecoveryTemplate/\(InstallerProductIdentity.recoveryAppName).app")
          try makeApp(template, identifier: "fixture.recovery")
          try sign(template, identifier: "fixture.recovery")
          let variable = InstallerProductIdentity.clientRequirementEnvironmentVariable
          var environment = [variable: client]
          if extra == "EnvironmentVariables" { environment["DYLD_INSERT_LIBRARIES"] = "/tmp/evil" }
          var plist: [String: Any] = [
            "Label": label, "BundleProgram": "Contents/Library/LaunchServices/\(label)",
            "MachServices": [label: true], "UserName": "root", "EnvironmentVariables": environment,
          ]
          if extra == "Program" { plist["Program"] = "/tmp/evil" }
          try FileManager.default.createDirectory(
            at: daemon.deletingLastPathComponent(), withIntermediateDirectories: true)
          try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: daemon)
          try sign(app, identifier: appIdentifier)
        } catch {
          remove()
          throw error
        }
      }

      func remove() { try? FileManager.default.removeItem(at: root) }

      private func makeApp(_ url: URL, identifier: String) throws {
        let executable = url.appendingPathComponent("Contents/MacOS/Fixture")
        try FileManager.default.createDirectory(
          at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let info = [
          "CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture",
          "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
          .write(to: url.appendingPathComponent("Contents/Info.plist"))
      }

      private func sign(_ url: URL, identifier: String) throws {
        _ = try run(["--force", "--sign", "-", "--identifier", identifier, url.path])
      }

      func codeHash(_ url: URL) throws -> String {
        let details = try run(["--display", "--verbose=4", url.path])
        return try XCTUnwrap(details.split(separator: "\n").first { $0.hasPrefix("CDHash=") })
          .dropFirst("CDHash=".count).description
      }

      func installedPlist(_ command: String) throws -> [String: Any] {
        let line = try XCTUnwrap(
          command.split(separator: "\n").first {
            $0.contains("/usr/bin/printf '%s'")
          })
        let quoted = line.components(separatedBy: "'")
        let encoded = try XCTUnwrap(quoted.count > 3 ? quoted[3] : nil)
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        return try XCTUnwrap(
          PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
      }

      private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
          throw NSError(
            domain: "InertCodeSigningFixture", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        return String(decoding: data, as: UTF8.self)
      }
    }
  }
#endif
