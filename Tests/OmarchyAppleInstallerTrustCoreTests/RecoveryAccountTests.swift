#if os(macOS)
  import CryptoKit
  import Foundation
  @testable import RecoveryAccountCore
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class RecoveryAccountTests: XCTestCase {
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

    func testStubVersionMetadataValidation() throws {
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
    let target = RecoveryAccountTarget(
      volumeName: "Omarchy", systemUUID: "11111111-1111-4111-8111-111111111111",
      dataUUID: "22222222-2222-4222-8222-222222222222",
      groupUUID: "33333333-3333-4333-8333-333333333333",
      prebootUUID: "44444444-4444-4444-8444-444444444444")

    func testInstallationTargetValidation() throws {
      try target.validate()
      for invalid in [
        RecoveryAccountTarget(
          volumeName: "", systemUUID: target.systemUUID, dataUUID: target.dataUUID,
          groupUUID: target.groupUUID, prebootUUID: target.prebootUUID),
        RecoveryAccountTarget(
          volumeName: "Omarchy", systemUUID: target.systemUUID, dataUUID: target.systemUUID,
          groupUUID: target.groupUUID, prebootUUID: target.prebootUUID),
        RecoveryAccountTarget(
          volumeName: "Omarchy", systemUUID: target.systemUUID, dataUUID: target.dataUUID,
          groupUUID: "00000000-0000-0000-0000-000000000000", prebootUUID: target.prebootUUID),
        RecoveryAccountTarget(
          volumeName: "Omarchy", systemUUID: "aaaaaaaa-1111-4111-8111-111111111111",
          dataUUID: target.dataUUID, groupUUID: target.groupUUID,
          prebootUUID: target.prebootUUID),
      ] {
        XCTAssertThrowsError(try invalid.validate())
      }
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
        if id == "stub-and-esp-installed" {
          value["apfs_vgid"] = target.groupUUID
          value["efi_partition"] = esp
          value["populated_partitions"] = [
            ["name": "EFI", "partition_uuid": esp], ["name": "Boot"], ["name": "Root"],
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
      var damaged = evidence
      damaged[ids[1]]!.append(32)
      XCTAssertThrowsError(
        try RecoveryAccountHandoff.completedEvidence(transcript: transcript, evidence: damaged))
      XCTAssertThrowsError(
        try RecoveryAccountHandoff.completedEvidence(
          transcript: transcript.dropLast(), evidence: evidence))
    }

    func testOnlyAnInstalledRecoveryReceiptMeansRecoveryFinished() {
      XCTAssertTrue(RecoveryAccountHandoff.isFinishedRecoveryReceipt(
        Data(#"{"schema":1,"status":"installed","mode":"raw"}"#.utf8)))
      XCTAssertFalse(RecoveryAccountHandoff.isFinishedRecoveryReceipt(
        Data(#"{"status":"prepared"}"#.utf8)))
      XCTAssertFalse(RecoveryAccountHandoff.isFinishedRecoveryReceipt(Data("not json".utf8)))
    }
  }
#endif
