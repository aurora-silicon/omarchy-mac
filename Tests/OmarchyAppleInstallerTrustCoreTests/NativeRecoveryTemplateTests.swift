#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativeRecoveryTemplateTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let app = root.appendingPathComponent("Source.app")
      try FileManager.default.createDirectory(
        at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let info: [String: Any] = [
        "CFBundleExecutable": "OmarchyRecovery",
        "CFBundleIdentifier": "org.example.native-recovery.fixture",
        "CFBundlePackageType": "APPL",
        "CFBundleDisplayName": InstallerProductIdentity.appName,
        "OmarchyRecoveryBuildMode": "recovery",
        "OmarchyRecoveryDataLayout": "external-install-data-v1",
      ]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
      let executable = app.appendingPathComponent("Contents/MacOS/OmarchyRecovery")
      try Data("synthetic executable".utf8).write(to: executable)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
      return (root, app)
    }

    func testSnapshotBindsCompleteInventoryAndDoesNotChangeSource() throws {
      let (root, app) = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      var verified = [URL]()
      let prepared = try NativeRecoveryTemplate.prepare(
        source: app, in: root, owner: geteuid(), requirement: "expected identity"
      ) { verified.append($0) }
      defer { prepared.remove() }
      XCTAssertEqual(verified, [app, prepared.app])
      let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
        with: Data(contentsOf: prepared.manifest)) as? [String: Any])
      XCTAssertEqual(manifest["schema"] as? Int, 1)
      XCTAssertEqual(manifest["buildMode"] as? String, "recovery")
      let files = try XCTUnwrap(manifest["files"] as? [String: [String: Any]])
      XCTAssertEqual(Set(files.keys), ["Contents/Info.plist", "Contents/MacOS/OmarchyRecovery"])
      XCTAssertEqual(files["Contents/MacOS/OmarchyRecovery"]?["bytes"] as? Int, 20)
      XCTAssertEqual(prepared.environment["OMARCHY_RECOVERY_REQUIREMENT"], "expected identity")
      prepared.remove()
      XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.directory.path))
    }

    func testWritableSymlinkPreviewAndNonExecutableInputsAreRejected() throws {
      for variation in ["writable", "symlink", "preview", "non-executable", "owner"] {
        let (root, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = app.appendingPathComponent("Contents/MacOS/OmarchyRecovery")
        switch variation {
        case "writable":
          try FileManager.default.setAttributes([.posixPermissions: 0o722], ofItemAtPath: executable.path)
        case "symlink":
          try FileManager.default.createSymbolicLink(
            at: app.appendingPathComponent("linked"), withDestinationURL: executable)
        case "preview":
          let info = app.appendingPathComponent("Contents/Info.plist")
          var values = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: info), format: nil) as? [String: Any])
          values["OmarchyRecoveryBuildMode"] = "preview"
          try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: info)
        case "non-executable":
          try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        default: break
        }
        XCTAssertThrowsError(try NativeRecoveryTemplate.prepare(
          source: app, in: root, owner: variation == "owner" ? geteuid() + 1 : geteuid(),
          requirement: "identity", verify: { _ in }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Source.app"])
      }
    }

    func testSignatureFailureAndMutationDuringSnapshotLeaveNoJobCopy() throws {
      for mutate in [false, true] {
        let (root, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try NativeRecoveryTemplate.prepare(
          source: app, in: root, owner: geteuid(), requirement: "identity"
        ) { _ in
          if mutate {
            try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/MacOS/OmarchyRecovery"))
          } else {
            throw NativeRecoveryTemplateError.invalidIdentity
          }
        })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Source.app"])
      }
    }

    func testFlatContainerReconstructsVerifiedPrivateAppWithoutApplications() throws {
      let (root, app) = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let archive = root.appendingPathComponent(NativeRecoveryTemplate.archiveFileName)
      try NativeRecoveryTemplate.archiveData(from: app).write(to: archive)
      try FileManager.default.removeItem(at: app)
      var checks = 0
      let prepared = try NativeRecoveryTemplate.prepare(
        archive: archive, in: root, owner: geteuid(), requirement: "pinned"
      ) { _ in checks += 1 }
      defer { prepared.remove() }
      XCTAssertEqual(checks, 1)
      XCTAssertEqual(try Data(contentsOf: prepared.app.appendingPathComponent("Contents/MacOS/OmarchyRecovery")), Data("synthetic executable".utf8))
      XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.manifest.path))
    }

    func testFlatContainerRejectsTraversalMalformedDataAndUnsignedApp() throws {
      for mode in ["traversal", "absolute", "empty-component", "collision", "malformed", "signature"] {
        let (root, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent(NativeRecoveryTemplate.archiveFileName)
        var bytes = try NativeRecoveryTemplate.archiveData(from: app)
        if mode == "malformed" { bytes = Data("not JSON".utf8) }
        else if mode != "signature" {
          var files = try JSONDecoder().decode([String: Data].self, from: bytes)
          let name = ["traversal": "Contents/../outside", "absolute": "/outside", "empty-component": "Contents//bad", "collision": "Contents/MacOS"][mode]!
          files[name] = Data("invalid".utf8)
          bytes = try JSONEncoder().encode(files)
        }
        try bytes.write(to: archive)
        XCTAssertThrowsError(try NativeRecoveryTemplate.prepare(
          archive: archive, in: root, owner: geteuid(), requirement: "pinned",
          verify: { _ in
            if mode == "signature" { throw NativeRecoveryTemplateError.invalidIdentity }
          }))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("native-recovery-") })
      }
    }

    func testReconstructedAppMustSatisfyTheActualPinnedCodeSignature() throws {
      let (root, app) = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let binary = app.appendingPathComponent("Contents/MacOS/OmarchyRecovery")
      try FileManager.default.removeItem(at: binary)
      let source = root.appendingPathComponent("entry.c")
      try Data("int main(void) { return 0; }\n".utf8).write(to: source)
      let compiler = Process()
      compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      compiler.arguments = ["clang", source.path, "-o", binary.path]
      try compiler.run()
      compiler.waitUntilExit()
      XCTAssertEqual(compiler.terminationStatus, 0)
      func codesign(_ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        return String(decoding: bytes, as: UTF8.self)
      }
      _ = try codesign(["--force", "--sign", "-", app.path])
      let description = try codesign(["--display", "--verbose=4", app.path])
      let hash = try XCTUnwrap(description.split(separator: "\n").first { $0.hasPrefix("CDHash=") })
      let requirement = "cdhash H\"" + hash.dropFirst(7) + "\""
      let archive = root.appendingPathComponent(NativeRecoveryTemplate.archiveFileName)
      try NativeRecoveryTemplate.archiveData(from: app).write(to: archive)
      let prepared = try NativeRecoveryTemplate.prepare(
        archive: archive, in: root, owner: geteuid(), requirement: requirement
      ) { try NativeRecoveryTemplate.verify($0, requirement: requirement) }
      defer { prepared.remove() }
      let wrong = "cdhash H\"" + String(repeating: "0", count: 40) + "\""
      XCTAssertThrowsError(try NativeRecoveryTemplate.prepare(
        archive: archive, in: root, owner: geteuid(), requirement: wrong
      ) { try NativeRecoveryTemplate.verify($0, requirement: wrong) })
    }

    func testPublicationRetainsOldTreeUntilTheNewEntryIsDurable() throws {
      let (root, app) = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let prepared = try NativeRecoveryTemplate.prepare(
        source: app, in: root, owner: geteuid(), requirement: "identity", verify: { _ in })
      defer { prepared.remove() }
      let destination = root.appendingPathComponent("retained")
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      try Data("previous".utf8).write(to: destination.appendingPathComponent("previous.txt"))
      var flushed = false
      XCTAssertThrowsError(try NativeRecoveryTemplate.publish(
        prepared, to: destination, owner: geteuid(), verify: { _ in },
        flushTree: { _ in flushed = true }, flushDirectory: { _ in
          XCTAssertTrue(flushed)
          throw NativeRecoveryTemplateError.unsafeTemplate
        }))
      XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(InstallerProductIdentity.recoveryAppBundleName).path))
      let previous = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter {
        $0.lastPathComponent.hasPrefix(".native-recovery-")
      }
      XCTAssertEqual(previous.count, 1)
      XCTAssertEqual(try Data(contentsOf: previous[0].appendingPathComponent("previous.txt")), Data("previous".utf8))
    }

    func testHelperRequirementDoesNotAcceptUnpinnedAdHocCode() {
      XCTAssertNil(NativeRecoveryTemplate.requirement(environment: [:]))
      XCTAssertNil(NativeRecoveryTemplate.requirement(environment: ["OMARCHY_RECOVERY_TEMPLATE_REQUIREMENT": "anchor trusted"]))
      let pin = "cdhash H\"" + String(repeating: "a", count: 40) + "\""
      XCTAssertEqual(NativeRecoveryTemplate.requirement(environment: ["OMARCHY_RECOVERY_TEMPLATE_REQUIREMENT": pin]), pin)
      let client = "anchor apple generic and identifier \"\(InstallerProductIdentity.appIdentifier)\" and certificate leaf[subject.OU] = \"ABCDE12345\""
      let requirement = NativeRecoveryTemplate.requirement(environment: [InstallerProductIdentity.clientRequirementEnvironmentVariable: client])
      XCTAssertTrue(requirement?.contains("identifier \"org.aurorasilicon.omarchy.recovery.recovery\"") == true)
      XCTAssertTrue(requirement?.contains("ABCDE12345") == true)
    }
  }
#endif
