#if os(macOS)
  import CryptoKit
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class LegacyRecoveryHandoffTests: XCTestCase {
    private let group = "11111111-1111-4111-8111-111111111111"
    private let launcher = Data("fixture launcher\n".utf8)
    private let prefix = "Finish Installation.app/Contents/"

    private func fixture() throws -> (URL, [String: Data]) {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      addTeardownBlock { try? FileManager.default.removeItem(at: root) }
      let plist = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleExecutable": "step2_launcher.sh"], format: .xml, options: 0)
      return (root, [
        ".IAPhysicalMedia": try PropertyListSerialization.data(
          fromPropertyList: ["AppName": "Finish Installation.app"], format: .xml, options: 0),
        prefix + "Info.plist": plist,
        prefix + "MacOS/step2_launcher.sh": launcher,
        prefix + "Resources/step2.sh": Data("#!/bin/sh\nVGID=\"\(group)\"\n".utf8),
        prefix + "Resources/boot.bin": Data([1, 2, 3, 4]),
      ])
    }

    private var verifier: LegacyRecoveryHandoff {
      LegacyRecoveryHandoff(
        authenticatedLauncherDigest:
          SHA256.hash(data: launcher).map { String(format: "%02x", $0) }.joined())
    }

    private func fingerprint(
      _ root: URL, _ files: [String: Data], using verifier: LegacyRecoveryHandoff? = nil
    ) throws -> String? {
      try (verifier ?? self.verifier).fingerprint(system: root, group: group) { path, limit in
        let name = String(path.path.dropFirst(root.path.count + 1))
        guard let data = files[name], !data.isEmpty, data.count <= limit else {
          throw CocoaError(.fileReadNoSuchFile)
        }
        return data
      }
    }

    func testCompleteLegacyContractIsStableAndBindsEveryInput() throws {
      let (root, files) = try fixture()
      let original = try XCTUnwrap(fingerprint(root, files))
      XCTAssertEqual(try fingerprint(root, files), original)
      var changed = files
      changed[prefix + "Resources/boot.bin"]!.append(5)
      XCTAssertNotEqual(try fingerprint(root, changed), original)
      for name in files.keys {
        var missing = files
        missing.removeValue(forKey: name)
        XCTAssertThrowsError(try fingerprint(root, missing), name)
      }
    }

    func testWrongLauncherAndVolumeGroupAreRejected() throws {
      let (root, files) = try fixture()
      // The production verifier never trusts this synthetic fixture launcher.
      XCTAssertThrowsError(try fingerprint(root, files, using: LegacyRecoveryHandoff()))
      var changed = files
      changed[prefix + "MacOS/step2_launcher.sh"]!.append(0)
      XCTAssertThrowsError(try fingerprint(root, changed))
      changed = files
      changed[prefix + "Resources/step2.sh"] = Data("#!/bin/sh\nVGID=\"wrong\"\n".utf8)
      XCTAssertThrowsError(try fingerprint(root, changed))
    }

    func testNativeOrInterruptedNativeStateNeverFallsBack() throws {
      for marker in [InstallerProductIdentity.recoveryAppBundleName, "Aurora/Recovery"] {
        let (root, files) = try fixture()
        let path = root.appendingPathComponent(marker)
        try FileManager.default.createDirectory(
          at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "/absent")
        XCTAssertNil(try fingerprint(root, files))
      }
    }

    func testRecoveryMarkerMustLaunchTheVerifiedApp() throws {
      let (root, files) = try fixture()
      for marker: [String: String] in [[:], ["AppName": "Another.app"]] {
        var changed = files
        changed[".IAPhysicalMedia"] = try PropertyListSerialization.data(
          fromPropertyList: marker, format: .xml, options: 0)
        XCTAssertThrowsError(try fingerprint(root, changed))
      }
    }

    func testOldRepliesRemainNativeAndUnknownKindsAreRejected() throws {
      let old = try JSONDecoder().decode(RecoveryAccountReply.self, from: Data("{}".utf8))
      XCTAssertEqual(old.effectiveHandoffKind, .native)
      XCTAssertThrowsError(
        try JSONDecoder().decode(
          RecoveryAccountReply.self, from: Data("{\"handoffKind\":\"unknown\"}".utf8)))
    }

    func testWritableOrRedirectedParentCannotSupplyRecoveryInputs() throws {
      let (root, _) = try fixture()
      let directory = root.appendingPathComponent("app/Resources")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let relative = "app/Resources/input"
      try LegacyRecoveryHandoff.requireProtectedParents(
        system: root, relativePath: relative, expectedOwnerID: geteuid())
      try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
      XCTAssertThrowsError(
        try LegacyRecoveryHandoff.requireProtectedParents(
          system: root, relativePath: relative, expectedOwnerID: geteuid()))
      try FileManager.default.removeItem(at: directory)
      try FileManager.default.createSymbolicLink(atPath: directory.path, withDestinationPath: root.path)
      XCTAssertThrowsError(
        try LegacyRecoveryHandoff.requireProtectedParents(
          system: root, relativePath: relative, expectedOwnerID: geteuid()))
    }
  }
#endif
