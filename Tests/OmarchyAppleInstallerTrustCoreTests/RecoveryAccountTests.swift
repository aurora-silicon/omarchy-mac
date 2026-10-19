#if os(macOS)
  import CryptoKit
  import Darwin
  import Foundation
  @testable import RecoveryAccountCore
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class RecoveryAccountTests: XCTestCase {
    func testExternalRecoveryConfigurationDoesNotFallBackFromAnIncompleteBaseline() throws {
      let fm = FileManager.default
      let system = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try fm.createDirectory(at: system, withIntermediateDirectories: true)
      defer { try? fm.removeItem(at: system) }
      let appName = InstallerProductIdentity.recoveryAppBundleName
      let legacy = system.appendingPathComponent(
        appName + "/Contents/Resources/install-config.json")
      XCTAssertEqual(
        try RecoveryInstallData.configuration(system: system, appName: appName), legacy)
      let external = try RecoveryInstallData.directory(system: system)
      try fm.createDirectory(at: external, withIntermediateDirectories: true)
      XCTAssertEqual(
        try RecoveryInstallData.configuration(system: system, appName: appName),
        external.appendingPathComponent("install-config.json"))
      try fm.removeItem(at: external)
      try fm.createSymbolicLink(at: external, withDestinationURL: system)
      XCTAssertThrowsError(try RecoveryInstallData.directory(system: system))
    }

    func testLegacyRecoveryDataMigratesWithoutChangingTheSignedBundleOrAccountState() throws {
      let fm = FileManager.default
      let system = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let appName = InstallerProductIdentity.recoveryAppBundleName
      let resources = system.appendingPathComponent(appName + "/Contents/Resources")
      let payloads = resources.appendingPathComponent("AuraPayloads")
      try fm.createDirectory(at: payloads, withIntermediateDirectories: true)
      defer { try? fm.removeItem(at: system) }
      let config = try JSONSerialization.data(withJSONObject: [
        "schema": 2, "systemUUID": target.systemUUID, "groupUUID": target.groupUUID,
        "prebootUUID": target.prebootUUID,
      ])
      try config.write(to: resources.appendingPathComponent("install-config.json"))
      let names = [
        "raw/aura-raw.bin", "raw/boot.bin", "vendorfw/firmware.tar",
        "vendorfw/firmware.cpio", "vendorfw/manifest.txt",
      ]
      var entries: [String: [String: Any]] = [:]
      for name in names {
        let path = payloads.appendingPathComponent(name)
        let data = Data(name.utf8)
        try fm.createDirectory(
          at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
        entries[name] = [
          "bytes": data.count,
          "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        ]
      }
      let manifest = try JSONSerialization.data(withJSONObject: ["schema": 2, "files": entries])
      try manifest.write(to: payloads.appendingPathComponent("manifest.json"))
      let state = system.appendingPathComponent("Aurora/Recovery/State")
      try fm.createDirectory(at: state, withIntermediateDirectories: true)
      let sentinel = Data("account journal".utf8)
      try sentinel.write(to: state.appendingPathComponent("keep.json"))
      let output = try RecoveryInstallData.migrateLegacy(
        system: system, appName: appName, target: target, read: fixtureRead)
      XCTAssertEqual(
        try Data(contentsOf: output.appendingPathComponent("install-config.json")), config)
      XCTAssertEqual(
        try Data(contentsOf: resources.appendingPathComponent("install-config.json")), config)
      XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("keep.json")), sentinel)
      for name in names {
        XCTAssertEqual(
          try Data(contentsOf: output.appendingPathComponent("AuraPayloads/" + name)),
          Data(name.utf8))
        XCTAssertEqual(try Data(contentsOf: payloads.appendingPathComponent(name)), Data(name.utf8))
      }
      // A later app update uses the published baseline, even if the old app is gone.
      try fm.removeItem(at: system.appendingPathComponent(appName))
      XCTAssertEqual(
        try RecoveryInstallData.migrateLegacy(
          system: system, appName: appName, target: target, read: fixtureRead),
        output)
      // A retry must revalidate all payloads, even after a prior publication.
      let firmware = output.appendingPathComponent("AuraPayloads/vendorfw/firmware.tar")
      try Data("tampered".utf8).write(to: firmware)
      XCTAssertThrowsError(
        try RecoveryInstallData.migrateLegacy(
          system: system, appName: appName, target: target, read: fixtureRead))
      try Data("vendorfw/firmware.tar".utf8).write(to: firmware)
      let payloadRoot = output.appendingPathComponent("AuraPayloads")
      try fm.moveItem(at: payloadRoot, to: output.appendingPathComponent("saved-payloads"))
      try fm.createSymbolicLink(
        at: payloadRoot, withDestinationURL: output.appendingPathComponent("saved-payloads"))
      XCTAssertThrowsError(try RecoveryInstallData.payloadDirectory(system: system))
      XCTAssertThrowsError(
        try RecoveryInstallData.migrateLegacy(
          system: system, appName: appName, target: target, read: fixtureRead))
    }

    func testTokenAuthorityWaitsForNativePersistence() throws {
      let id = UUID().uuidString
      let hashes = [Data("fixture-hash".utf8)]
      var reads = 0
      try RecoveryAccountInstaller.waitForTokenAuthority(
        generatedUID: id, passwordHashes: hashes,
        read: {
          reads += 1
          return [
            "generateduid": [id], "ShadowHashData": hashes,
            "authentication_authority": reads < 3 ? [] : [";SecureToken;"],
          ]
        }, pause: {})
      XCTAssertEqual(reads, 3)
    }

    func testTokenAuthorityRejectsChangedIdentityOrPasswordHash() {
      let id = UUID().uuidString
      let hashes = [Data("fixture-hash".utf8)]
      let changes: [[String: Any]] = [
        ["generateduid": [UUID().uuidString], "ShadowHashData": hashes],
        ["generateduid": [id], "ShadowHashData": [Data("changed".utf8)]],
      ]
      for changed in changes {
        XCTAssertThrowsError(
          try RecoveryAccountInstaller.waitForTokenAuthority(
            generatedUID: id, passwordHashes: hashes,
            read: {
              changed.merging(["authentication_authority": [";SecureToken;"]]) { _, new in new }
            },
            pause: {}))
      }
    }

    func testTokenAuthorityDoesNotAcceptAnUnpersistedMarker() {
      let id = UUID().uuidString
      let hashes = [Data("fixture-hash".utf8)]
      XCTAssertThrowsError(
        try RecoveryAccountInstaller.waitForTokenAuthority(
          generatedUID: id, passwordHashes: hashes, timeout: 0,
          read: { ["generateduid": [id], "ShadowHashData": hashes] }, pause: {}))
    }

    func testShutdownRequiresSelectedTargetVolumeGroup() throws {
      try RecoveryAccountHandoff.requireStartupSelection(
        target, info: ["APFSVolumeGroupID": target.groupUUID])
      // bless may identify either member of the same APFS volume group.
      try RecoveryAccountHandoff.requireStartupSelection(
        target, info: ["APFSVolumeGroupID": target.groupUUID, "VolumeUUID": target.dataUUID])
      XCTAssertThrowsError(
        try RecoveryAccountHandoff.requireStartupSelection(
          target, info: ["APFSVolumeGroupID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"]))
      XCTAssertThrowsError(try RecoveryAccountHandoff.requireStartupSelection(target, info: [:]))
    }

    func testCompletedInstallationRequiresLivePartitionIdentities() throws {
      let ids = (1...4).map { String(format: "%08d-1111-4111-8111-111111111111", $0) }
      let evidence = [
        "apfs-target-prepared": try JSONSerialization.data(withJSONObject: [
          "uuid": ids[0], "size_bytes": 6000,
        ]),
        "stub-and-esp-installed": try JSONSerialization.data(withJSONObject: [
          "populated_partitions": (1...3).map {
            ["partition_uuid": ids[$0], "partition_size_bytes": 1000] as [String: Any]
          }
        ]),
      ]
      let parts: [[String: Any]] = ids.enumerated().map {
        [
          "DiskUUID": $0.element, "Size": $0.offset == 0 ? 6000 : 1000,
          "DeviceIdentifier": "disk9s\($0.offset + 3)",
        ]
      }
      func check(_ partitions: [[String: Any]]) throws {
        let bytes = try PropertyListSerialization.data(
          fromPropertyList: ["AllDisksAndPartitions": [["Partitions": partitions]]],
          format: .xml, options: 0)
        let listing = try XCTUnwrap(
          PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        try RecoveryAccountHandoff.requireLivePartitions(
          evidence: evidence, listing: listing)
      }
      try check(parts)
      // Device renumbering is harmless; UUID and size carry the identity.
      try check(parts.map { $0.merging(["DeviceIdentifier": "renumbered"]) { _, new in new } })
      XCTAssertThrowsError(try check(Array(parts.dropLast())))
      XCTAssertThrowsError(try check(parts + [parts[0]]))
      var resized = parts
      resized[3]["Size"] = 2000
      XCTAssertThrowsError(try check(resized))
      XCTAssertThrowsError(try check([]))
    }

    func testNativeStartupDiskRequiresValidStubVersionMetadata() throws {
      let valid = try PropertyListSerialization.data(
        fromPropertyList: [
          "ProductName": "macOS", "ProductVersion": "26.6.2", "ProductBuildVersion": "25G83",
        ], format: .xml, options: 0)
      try RecoveryVersionMetadata.validate(valid)
      for value in [
        [String: String](), ["ProductName": "macOS"],
        ["ProductName": "macOS", "ProductVersion": "26.6.2", "ProductBuildVersion": ""],
      ] {
        let data = try PropertyListSerialization.data(
          fromPropertyList: value, format: .xml, options: 0)
        XCTAssertThrowsError(try RecoveryVersionMetadata.validate(data))
      }
    }
    private func fixtureRead(_ path: URL, _ limit: Int) throws -> Data {
      let bytes = try Data(contentsOf: path)
      guard !bytes.isEmpty && bytes.count <= limit else {
        throw AccountSetupFailure("Invalid test fixture")
      }
      return bytes
    }

    func testDeferredHandoffFinalizationDisarmsLauncherAndRestoresVersion() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let core = root.appendingPathComponent("System/Library/CoreServices")
      let state = root.appendingPathComponent("Aurora/Recovery/State")
      try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let version = try PropertyListSerialization.data(
        fromPropertyList: [
          "ProductName": "macOS", "ProductVersion": "26.6.2",
          "ProductBuildVersion": "25G83",
        ], format: .xml, options: 0)
      let enabled = core.appendingPathComponent("SystemVersion.plist")
      let hidden = core.appendingPathComponent("SystemVersion-disabled.plist")
      let marker = root.appendingPathComponent(".IAPhysicalMedia")
      let disabled = root.appendingPathComponent("IAPhysicalMedia-disabled.plist")
      let receipt = state.appendingPathComponent("installation.json")
      let launch = try PropertyListSerialization.data(
        fromPropertyList: ["AppName": InstallerProductIdentity.recoveryAppBundleName],
        format: .xml, options: 0)
      // Skip leaves the completed install visible, with its launcher disabled.
      try RecoveryFileTransaction.write(version, to: enabled)
      try RecoveryFileTransaction.write(launch, to: disabled)
      try RecoveryFileTransaction.write(
        JSONSerialization.data(withJSONObject: [
          "status": "installed",
          "recoveryAccountRequired": true, "recoveryAccountDeferred": true,
        ]), to: receipt)
      // The macOS handoff re-arms initial Recovery and hides its metadata.
      try RecoveryFileTransaction.write(launch, to: marker)
      try RecoveryVersionMetadata.hideForInitialRecovery(system: root, read: fixtureRead)
      XCTAssertTrue(FileManager.default.fileExists(atPath: hidden.path))
      let transaction = try RecoveryFileTransaction(
        directory: root.appendingPathComponent("snapshot"),
        files: [enabled, hidden, marker, disabled, receipt])
      try transaction.clearImmutableFlags()
      // Account ownership may finish before boot enrollment. A policy/enrollment
      // failure must leave the original autolaunch and version available to retry.
      let pending = try RecoveryVersionMetadata.finishAccountSetup(
        system: root, installationPending: true, read: fixtureRead)
      XCTAssertTrue(pending.isEmpty)
      XCTAssertEqual(try Data(contentsOf: marker), launch)
      XCTAssertEqual(try Data(contentsOf: hidden), version)
      let stillDeferred =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: receipt)) as? [String: Any]
      XCTAssertEqual(stillDeferred?["recoveryAccountDeferred"] as? Bool, true)
      let relocated = try RecoveryVersionMetadata.finishAccountSetup(
        system: root, read: fixtureRead)
      try transaction.commit(relocated: relocated)
      XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: hidden.path))
      XCTAssertEqual(try Data(contentsOf: enabled), version)
      XCTAssertEqual(try Data(contentsOf: disabled), launch)
      let record =
        try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any]
      XCTAssertEqual(record?["recoveryAccountDeferred"] as? Bool, false)
      XCTAssertEqual(record?["recoveryAccountRequired"] as? Bool, true)
      // Repeated completion is harmless. File rollback restores the re-armed state.
      try RecoveryVersionMetadata.finishAccountSetup(system: root, read: fixtureRead)
      try transaction.restore()
      XCTAssertEqual(try Data(contentsOf: marker), launch)
      XCTAssertEqual(try Data(contentsOf: hidden), version)
    }

    func testAccountCompletionRestoresRelocatedVersionFlags() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let core = root.appendingPathComponent("System/Library/CoreServices")
      try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let hidden = core.appendingPathComponent("SystemVersion-disabled.plist")
      let visible = core.appendingPathComponent("SystemVersion.plist")
      let version = try PropertyListSerialization.data(
        fromPropertyList: [
          "ProductName": "macOS", "ProductVersion": "26.6.2",
          "ProductBuildVersion": "25G83",
        ], format: .xml, options: 0)
      try RecoveryFileTransaction.write(version, to: hidden)
      guard chflags(hidden.path, UInt32(UF_NODUMP)) == 0 else {
        throw XCTSkip("The test filesystem does not support file flags")
      }
      let transaction = try RecoveryFileTransaction(
        directory: root.appendingPathComponent("snapshot"), files: [hidden, visible])
      try transaction.clearImmutableFlags()
      let relocated = try RecoveryVersionMetadata.finishAccountSetup(
        system: root, read: fixtureRead)
      try transaction.commit(relocated: relocated)
      var info = stat()
      XCTAssertEqual(lstat(visible.path, &info), 0)
      XCTAssertEqual(info.st_flags & UInt32(UF_NODUMP), UInt32(UF_NODUMP))
      XCTAssertEqual(try Data(contentsOf: visible), version)
    }

    let target = RecoveryAccountTarget(
      volumeName: "Omarchy", systemUUID: "11111111-1111-4111-8111-111111111111",
      dataUUID: "22222222-2222-4222-8222-222222222222",
      groupUUID: "33333333-3333-4333-8333-333333333333",
      prebootUUID: "44444444-4444-4444-8444-444444444444")

    func testRecoveryAccountInputAndIdentityValidation() throws {
      try target.validate()
      XCTAssertTrue(RecoveryAccountInstaller.validName("omarchy-owner"))
      for name in ["root", "daemon", "nobody", "../owner", "name\nquit", "OWNER", "-owner"] {
        XCTAssertFalse(RecoveryAccountInstaller.validName(name))
      }
      try RecoveryAccountInstaller.validatePassword(Data("short".utf8))
      for value in [Data(), Data([0]), Data("line\nbreak".utf8), Data(repeating: 65, count: 4097)] {
        XCTAssertThrowsError(try RecoveryAccountInstaller.validatePassword(value))
      }
      let record = RecoveryAccountRecord(
        target: target, username: "owner", generatedUID: UUID().uuidString, phase: "prepared")
      try record.validate()
      XCTAssertEqual(
        try JSONDecoder().decode(RecoveryAccountRecord.self, from: JSONEncoder().encode(record)),
        record)
    }

    func testRelativeAccountLookupHandlesDifferentMountSuffixes() {
      XCTAssertEqual(
        RecoveryAccountInstaller.relativePath(
          from: URL(fileURLWithPath: "/Volumes/Omarchy 1/private"),
          to: URL(fileURLWithPath: "/Volumes/Omarchy - Data 2/private/var")),
        "../../Omarchy - Data 2/private/var")
      XCTAssertEqual(
        RecoveryAccountInstaller.relativePath(
          from: URL(fileURLWithPath: "/Volumes/Omarchy 1"),
          to: URL(fileURLWithPath: "/Volumes/Omarchy - Data 2/private/var")),
        "../Omarchy - Data 2/private/var")
    }

    func testCommandUsesStdinAndBoundsOutputAndTime() throws {
      let secret = Data("unit-test-only\n".utf8)
      let echoed = try AccountNativeCommand.run("/bin/cat", [], input: secret)
      XCTAssertEqual(echoed.status, 0)
      XCTAssertEqual(echoed.output, secret)
      let earlyExit = try AccountNativeCommand.run(
        "/usr/bin/true", [], input: Data(repeating: 65, count: 8192))
      XCTAssertEqual(earlyExit.status, 0)
      XCTAssertThrowsError(try AccountNativeCommand.run("/bin/sleep", ["5"], timeout: 1))
      XCTAssertThrowsError(try AccountNativeCommand.run("/usr/bin/yes", [], timeout: 3))
    }

    func testCompletedCheckpointBindsTargetAndRejectsDamage() throws {
      let digest = String(repeating: "a", count: 64)
      let ids = ["apfs-target-prepared", "stub-and-esp-installed", "recovery-handoff-prepared"]
      let esp = "55555555-5555-4555-8555-555555555555"
      var evidence = [String: Data]()
      for id in ids {
        var value: [String: Any] = ["plan_digest": digest]
        if id == "apfs-target-prepared" {
          value["uuid"] = target.systemUUID
          value["size_bytes"] = 6000
        }
        if id == "stub-and-esp-installed" {
          value["apfs_vgid"] = target.groupUUID
          value["efi_partition"] = esp
          value["populated_partitions"] = [
            ["name": "EFI", "partition_uuid": esp, "partition_size_bytes": 1000],
            ["name": "Boot", "partition_uuid": target.dataUUID, "partition_size_bytes": 2000],
            ["name": "Root", "partition_uuid": target.prebootUUID, "partition_size_bytes": 3000],
          ]
        }
        evidence[id] = try JSONSerialization.data(withJSONObject: value)
      }
      var rows: [[String: Any]] = []
      func add(_ type: String, _ payload: [String: Any]) {
        rows.append([
          "schema_version": 1, "sequence": rows.count + 1, "type": type, "payload": payload,
        ])
      }
      add("inspection", ["device_identifier": "apple,j700", "support": "supported"])
      add("inventory", [:])
      add("plan", ["plan_digest": digest])
      for id in ids {
        add("event", ["name": id, "plan_digest": digest])
        let hash = SHA256.hash(data: evidence[id]!).map { String(format: "%02x", $0) }.joined()
        add(
          "checkpoint",
          ["identifier": id, "plan_digest": digest, "evidence_digest": "sha256:" + hash])
      }
      add("completion", ["plan_digest": digest, "outcome": "awaiting_recovery"])
      var transcript = Data()
      for row in rows {
        transcript.append(try JSONSerialization.data(withJSONObject: row))
        transcript.append(10)
      }
      let result = try RecoveryAccountHandoff.completedEvidence(
        transcript: transcript, evidence: evidence)
      XCTAssertEqual(result.group, target.groupUUID)
      XCTAssertEqual(result.esp, esp)
      let parts: [[String: Any]] = [
        ["DiskUUID": target.systemUUID, "Size": UInt64(6000)],
        ["DiskUUID": esp, "Size": UInt64(1000)],
        ["DiskUUID": target.dataUUID, "Size": UInt64(2000)],
        ["DiskUUID": target.prebootUUID, "Size": UInt64(3000)],
      ]
      for kind in [RecoveryHandoffKind.native, .legacy] {
        let verified = try RecoveryAccountHandoff.verifiedCompletion(
          binding: digest, transcript: transcript, evidence: evidence,
          listing: ["AllDisksAndPartitions": [["Partitions": parts]]],
          resolve: { group, observedESP in
            XCTAssertEqual(group, self.target.groupUUID)
            XCTAssertEqual(observedESP, esp)
            return (self.target, kind, kind == .legacy ? "bound-legacy-files" : nil)
          }, finished: { _ in false })
        XCTAssertEqual(verified?.handoffKind, kind)
        XCTAssertEqual(verified?.target, target)
        XCTAssertThrowsError(
          try RecoveryAccountHandoff.verifiedCompletion(
            binding: digest, transcript: transcript, evidence: evidence,
            listing: ["AllDisksAndPartitions": [["Partitions": Array(parts.dropLast())]]],
            resolve: { _, _ in XCTFail("Changed disk must be rejected first"); return (self.target, kind, nil) },
            finished: { _ in false }))
      }
      var damaged = evidence
      damaged[ids[1]]!.append(32)
      XCTAssertThrowsError(
        try RecoveryAccountHandoff.completedEvidence(transcript: transcript, evidence: damaged))
      XCTAssertThrowsError(
        try RecoveryAccountHandoff.completedEvidence(
          transcript: transcript.dropLast(), evidence: evidence))
    }

    func testOnlyAnInstalledRecoveryReceiptMeansRecoveryFinished() {
      XCTAssertTrue(
        RecoveryAccountHandoff.isFinishedRecoveryReceipt(
          Data(#"{"schema":1,"status":"installed","mode":"raw"}"#.utf8)))
      XCTAssertFalse(
        RecoveryAccountHandoff.isFinishedRecoveryReceipt(
          Data(#"{"status":"prepared"}"#.utf8)))
      XCTAssertFalse(
        RecoveryAccountHandoff.isFinishedRecoveryReceipt(
          Data(#"{"status":"installed","recoveryAccountDeferred":true}"#.utf8)))
      XCTAssertFalse(RecoveryAccountHandoff.isFinishedRecoveryReceipt(Data("not json".utf8)))
      XCTAssertFalse(
        RecoveryAccountHandoff.isFinishedRecoveryReceipt(
          Data(#"{"schema":1,"status":"installed","mode":"raw"}"#.utf8),
          hasPendingOperation: true))
    }
  }
#endif
