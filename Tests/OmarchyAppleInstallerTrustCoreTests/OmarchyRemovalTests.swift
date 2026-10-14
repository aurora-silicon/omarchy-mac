#if os(macOS)
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class OmarchyRemovalTests: XCTestCase {
    typealias F = RemovalFixtures

    // MARK: Recognised layouts

    func testConvergedLayoutFromM2ReturnsAllFourPartitionsToMacOS() throws {
      let plan = try OmarchyRemovalPlan(disks: FakeRemovalDisk())
      XCTAssertEqual(plan.kind, .installation)
      XCTAssertEqual(plan.installation?.name, "Omarchy")
      XCTAssertEqual(
        plan.members.map(\.uuid),
        [F.convergedInstall.stub, F.convergedInstall.esp] + F.convergedInstall.linux)
      XCTAssertEqual(plan.reclaimBytes, 319_999_180_800)
      XCTAssertEqual(plan.targetMacOSBytes, 994_662_584_320)
    }

    func testANeoInstallWithItsMacos26StubIsRecognised() throws {
      let disk = FakeRemovalDisk(F.neoMacos26(), install: F.convergedInstall)
      let plan = try OmarchyRemovalPlan(disks: disk)
      XCTAssertEqual(plan.kind, .installation)
      XCTAssertEqual(
        plan.members.map(\.uuid),
        [F.convergedInstall.stub, F.convergedInstall.esp] + F.convergedInstall.linux)
    }

    func testANeoStubBootingAurorasJ700Stage1IsRecognised() throws {
      let disk = FakeRemovalDisk(F.neoMacos26(), install: F.convergedInstall)
      disk.files!.stubBootObject = Self.auroraStage1(esp: F.convergedInstall.esp.lowercased())
      let plan = try OmarchyRemovalPlan(disks: disk)
      XCTAssertEqual(plan.kind, .installation)
      XCTAssertEqual(
        plan.members.map(\.uuid),
        [F.convergedInstall.stub, F.convergedInstall.esp] + F.convergedInstall.linux)
    }

    func testAnAuroraStage1MustNameThisESPInOneValidBlock() {
      let esp = F.convergedInstall.esp.lowercased()
      let versionTwo = Self.auroraStage1(esp: esp, version: 2)
      let cases: [Data] = [
        Self.auroraStage1(esp: F.id(77).lowercased()),
        Self.auroraStage1(esp: esp, corruptCRC: true),
        versionTwo,
        Self.auroraStage1(esp: esp) + Self.auroraStage1(esp: esp),
      ]
      for bootObject in cases {
        let disk = FakeRemovalDisk(F.neoMacos26(), install: F.convergedInstall)
        disk.files!.stubBootObject = bootObject
        XCTAssertThrowsError(try OmarchyRemovalPlan(disks: disk)) {
          XCTAssertTrue(
            ($0 as? RemovalFailure)?.message.contains(
              "the m1n1 boot object in its startup container doesn’t point to this EFI partition")
              ?? false, "\($0)")
        }
      }
    }

    /// Aurora's J700 Stage 1 as aurora-silicon/m1n1 tools/fill_stage1_config.py
    /// fills it: asahi's m1n1 version marker, one config block, a STACKBOT tail.
    static func auroraStage1(esp: String, version: UInt32 = 1, corruptCRC: Bool = false) -> Data {
      func le(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
      }
      var body = le(version) + le(5000)
      body += Array(esp.utf8) + [UInt8](repeating: 0, count: 40 - esp.utf8.count)
      let path = Array(";m1n1/boot.bin".utf8)
      body += path + [UInt8](repeating: 0, count: 192 - path.count)
      var image = Data("m1n1 stage 1 ##m1n1_ver##v1.6.1\0 code STACKBOT data ".utf8)
      image.append(Data("AURORA-S1-CFG01\0".utf8))
      image.append(contentsOf: body + le(RemovalEvidence.crc32(body) ^ (corruptCRC ? 1 : 0)))
      image.append(Data(" more code STACKBOT".utf8))
      return image
    }

    func testOlderOmarchyMacInstallIsRecognisedWithItsOneRootPartition() throws {
      let disk = FakeRemovalDisk(F.alarm(), install: F.alarmInstall)
      let plan = try OmarchyRemovalPlan(disks: disk)
      XCTAssertEqual(plan.installation?.name, "Asahi Alarm Minimal")
      XCTAssertEqual(plan.members.map(\.identifier), ["disk0s3", "disk0s4", "disk0s5"])
      XCTAssertEqual(plan.reclaimBytes, 32_800_505_856)
      XCTAssertEqual(
        plan.summary,
        "Found “Asahi Alarm Minimal”. Removal permanently deletes it and everything stored in it, then returns its space to macOS."
      )
      let ticket = plan.ticket(id: UUID())
      XCTAssertEqual(ticket.confirmation, "delete omarchy installation and data")
      XCTAssertEqual(
        ticket.deletions,
        [
          OmarchyRemovalItem(
            title: "Startup container “Asahi Alarm Minimal”", detail: "disk0s3 · APFS",
            bytes: 2_499_805_184),
          OmarchyRemovalItem(
            title: "EFI partition “EFI - ASAHI”", detail: "disk0s4", bytes: 524_288_000),
          OmarchyRemovalItem(title: "Linux partition", detail: "disk0s5", bytes: 29_776_412_672),
        ])
      XCTAssertEqual(
        ticket.kept.map(\.title),
        ["macOS “Macintosh HD”", "Apple system container", "Apple Recovery"])
      XCTAssertEqual(ticket.kept[0].detail, "disk0s2 · grows to 494.4 GB")
      XCTAssertTrue(ticket.notes.isEmpty)
    }

    func testFedoraInstallWithTrailingFreeSpaceReclaimsEverythingUpToRecovery() throws {
      let plan = try OmarchyRemovalPlan(
        disks: FakeRemovalDisk(F.fedora(), install: F.fedoraInstall))
      XCTAssertEqual(plan.members.count, 4)
      XCTAssertEqual(
        plan.reclaimBytes, 2_499_805_184 + 524_288_000 + 1_073_741_824 + 70_000_000_000)
    }

    func testUEFIOnlyInstallIsRemovableAndWarnsAboutExternalSystems() throws {
      let plan = try OmarchyRemovalPlan(
        disks: FakeRemovalDisk(F.uefiOnly(), install: F.uefiInstall))
      XCTAssertEqual(plan.members.map(\.identifier), ["disk0s3", "disk0s4"])
      XCTAssertEqual(
        plan.ticket(id: UUID()).notes,
        [
          "This installation has no Linux partitions of its own. If a Linux system elsewhere, for example on an external disk, starts through it, that system won’t start after removal. Its data isn’t touched."
        ])
    }

    func testFreeSpaceOnlyIsOfferedAsGrowOnlyWithItsOwnPhrase() throws {
      let plan = try OmarchyRemovalPlan(disks: FakeRemovalDisk(F.freeSpaceOnly(), install: nil))
      XCTAssertEqual(plan.kind, .freeSpace)
      XCTAssertTrue(plan.members.isEmpty)
      XCTAssertEqual(plan.reclaimBytes, 32_800_505_856)
      XCTAssertEqual(
        plan.summary,
        "No installation was found, but 32.8 GB directly after macOS is unallocated. macOS can take it back. Nothing will be deleted."
      )
      let ticket = plan.ticket(id: UUID())
      XCTAssertEqual(ticket.confirmation, "return free space to macos")
      XCTAssertTrue(ticket.deletions.isEmpty)
    }

    func testFreeSpaceOnlyIgnoresTheStartupSetting() throws {
      let disk = FakeRemovalDisk(F.freeSpaceOnly(), install: nil)
      disk.startupState = .unknown
      XCTAssertNoThrow(try OmarchyRemovalPlan(disks: disk))
    }

    func testFreeSpaceBeyondMacOSGrowthLimitIsRefused() {
      let disk = FakeRemovalDisk(F.freeSpaceOnly(), install: nil)
      disk.limitOverride = 461_584_287_744
      assertRefusal(
        disk,
        "32.8 GB directly after macOS is unallocated, but macOS reports it can only grow to 461.6 GB. Nothing was changed."
      )
    }

    func testSmallOrNoGapIsReportedAsNothingToDo() {
      assertRefusal(
        FakeRemovalDisk(F.snapshot(macOSSize: 400_000_000_000, [.free(500_000_000)]), install: nil),
        "No Omarchy installation, or other installation made with the Asahi installer, was found. 500.0 MB directly after macOS is unallocated; that’s too little to return, so it was left as it is. Nothing was changed."
      )
      assertRefusal(
        FakeRemovalDisk(F.snapshot(macOSSize: 400_000_000_000, []), install: nil),
        "No Omarchy installation, or other installation made with the Asahi installer, was found, and there’s no unallocated space after macOS. Nothing was changed."
      )
    }

    // MARK: Refusal fixtures

    func testForeignAPFSContainerIsRefusedByName() {
      assertRefusal(
        FakeRemovalDisk(F.foreignAPFS(), install: nil),
        "Found a partition that isn’t part of an installation made with the Asahi installer: disk0s3 (APFS container, 50.0 GB, volumes “Shared”). Removal only deletes partitions it can prove belong to one installation, so it stopped. Nothing was changed."
      )
    }

    func testWindowsPartitionIsRefusedByName() {
      assertRefusal(
        FakeRemovalDisk(F.windows(), install: nil),
        "Found a partition that isn’t part of an installation made with the Asahi installer: disk0s3 (Microsoft Basic Data, “BOOTCAMP”, 60.0 GB). Removal only deletes partitions it can prove belong to one installation, so it stopped. Nothing was changed."
      )
    }

    func testSecondMacOSIsRefused() {
      assertRefusal(
        FakeRemovalDisk(F.secondMacOS(), install: nil),
        "Found another system: disk0s3 (APFS container, 80.0 GB, volumes “Macintosh HD 2”, “Macintosh HD 2 - Data”, “Preboot”, “Recovery”, “VM”). It looks like another macOS installation, and removal never deletes one. Nothing was changed."
      )
    }

    func testFreeSpaceBehindAnotherPartitionIsRefusedAndExplained() {
      assertRefusal(
        FakeRemovalDisk(F.nonContiguousFree(), install: nil),
        "Found disk0s3 (Linux partition, 10.0 GB) without the startup container every installation made with the Asahi installer has. This looks like a partly removed installation, which needs a manual review. 32.8 GB of unallocated space isn’t directly after macOS: disk0s3 sits between them, so macOS can’t grow into it. Nothing was changed."
      )
    }

    func testInstallationNextToWindowsIsRefusedWithoutTouchingEither() {
      let snapshot = F.snapshot(
        macOSSize: 400_000_000_000,
        [
          .part(F.alarmInstall.stub, "Apple_APFS", 2_499_805_184),
          .part(F.alarmInstall.esp, "EFI", 524_288_000, name: "EFI - ASAHI"),
          .part(F.alarmInstall.linux[0], "Linux Filesystem", 29_776_412_672),
          .part(F.id(44), "Microsoft Basic Data", 60_000_000_000, name: "BOOTCAMP"),
        ], installs: [F.alarmInstall])
      let disk = FakeRemovalDisk(snapshot, install: F.alarmInstall)
      assertRefusal(
        disk,
        "Found a partition that isn’t part of an installation made with the Asahi installer: disk0s6 (Microsoft Basic Data, “BOOTCAMP”, 60.0 GB). Removal only deletes partitions it can prove belong to one installation, so it stopped. Nothing was changed."
      )
      XCTAssertEqual(disk.evidenceReads, 0)
    }

    func testTwoInstallationsAreRefused() {
      let snapshot = F.snapshot(
        macOSSize: 400_000_000_000,
        [
          .part(F.alarmInstall.stub, "Apple_APFS", 2_499_805_184),
          .part(F.alarmInstall.esp, "EFI", 524_288_000, name: "EFI - ASAHI"),
          .part(F.alarmInstall.linux[0], "Linux Filesystem", 29_776_412_672),
          .part(F.uefiInstall.stub, "Apple_APFS", 2_499_805_184),
          .part(F.uefiInstall.esp, "EFI", 500_170_752, name: "EFI - UEFI"),
        ], installs: [F.alarmInstall, F.uefiInstall])
      assertRefusal(
        FakeRemovalDisk(snapshot, install: F.alarmInstall),
        "Found more than one installation: disk0s3 (APFS container, 2.5 GB, volumes “Asahi Alarm Minimal”, “Asahi Alarm Minimal - Data”, “Preboot”, “Recovery”); disk0s6 (APFS container, 2.5 GB, volumes “UEFI boot”, “UEFI boot - Data”, “Preboot”, “Recovery”). Removal handles a single installation, so it stopped. Nothing was changed."
      )
    }

    func testPartlyRemovedInstallationIsRefused() {
      let snapshot = F.snapshot(
        macOSSize: 400_000_000_000,
        [
          .free(2_499_805_184),
          .part(F.alarmInstall.esp, "EFI", 524_288_000, name: "EFI - ASAHI"),
          .part(F.alarmInstall.linux[0], "Linux Filesystem", 29_776_412_672),
        ])
      assertRefusal(
        FakeRemovalDisk(snapshot, install: nil),
        "Found disk0s3 (EFI partition, “EFI - ASAHI”, 524.3 MB); disk0s4 (Linux partition, 29.8 GB) without the startup container every installation made with the Asahi installer has. This looks like a partly removed installation, which needs a manual review. Nothing was changed."
      )
    }

    func testUnexpectedPartitionShapesAreRefused() {
      let cases: [[F.Row]] = [
        // Startup container without its ESP.
        [.part(F.alarmInstall.stub, "Apple_APFS", 2_499_805_184)],
        // ESP not next to the startup container.
        [
          .part(F.alarmInstall.stub, "Apple_APFS", 2_499_805_184), .free(100_000_000),
          .part(F.alarmInstall.esp, "EFI", 524_288_000),
        ],
        // Three Linux partitions.
        [
          .part(F.alarmInstall.stub, "Apple_APFS", 2_499_805_184),
          .part(F.alarmInstall.esp, "EFI", 524_288_000),
          .part(F.id(5), "Linux Filesystem", 1_000_000_000),
          .part(F.id(6), "Linux Filesystem", 1_000_000_000),
          .part(F.id(7), "Linux Filesystem", 1_000_000_000),
        ],
        // ESP larger than 1 GiB.
        [
          .part(F.alarmInstall.stub, "Apple_APFS", 2_499_805_184),
          .part(F.alarmInstall.esp, "EFI", 2_000_000_000),
        ],
      ]
      for rows in cases {
        let disk = FakeRemovalDisk(
          F.snapshot(macOSSize: 400_000_000_000, rows, installs: [F.alarmInstall]),
          install: nil)
        XCTAssertThrowsError(try OmarchyRemovalPlan(disks: disk)) { error in
          XCTAssertTrue(
            (error as? RemovalFailure)?.message.hasPrefix(
              "Found a startup container, but the partitions with it don’t match one installation")
              == true, "\(error)")
        }
        XCTAssertEqual(disk.evidenceReads, 0)
      }
    }

    func testLUKSRetypedPartitionAndOddStubSizesAreRefused() {
      var luks = F.alarm()
      let root = luks.partitions[4]
      luks.partitions[4] = RemovalPartition(
        identifier: root.identifier, uuid: root.uuid,
        type: "CA7D7CCB-63ED-4C53-861C-1742536059CC", offset: root.offset, size: root.size,
        name: "")
      assertRefusal(
        FakeRemovalDisk(luks, install: F.alarmInstall),
        "Found a partition that isn’t part of an installation made with the Asahi installer: disk0s5 (CA7D7CCB-63ED-4C53-861C-1742536059CC, 29.8 GB). Removal only deletes partitions it can prove belong to one installation, so it stopped. Nothing was changed."
      )
      let grown = F.snapshot(
        macOSSize: 400_000_000_000,
        [
          .part(F.alarmInstall.stub, "Apple_APFS", 5_000_000_000),
          .part(F.alarmInstall.esp, "EFI", 524_288_000),
        ], installs: [F.alarmInstall])
      assertRefusalPrefix(FakeRemovalDisk(grown, install: nil), "Found another system:")
    }

    func testStubVolumesMustBeExactlyOneInstallationsVolumeGroup() {
      var snapshot = F.alarm()
      let index = snapshot.containers.firstIndex { $0.storeUUID == F.alarmInstall.stub }!
      let stub = snapshot.containers[index]
      snapshot.containers[index] = RemovalContainer(
        uuid: stub.uuid, storeUUID: stub.storeUUID,
        volumes: stub.volumes.map {
          $0.roles == ["Data"]
            ? RemovalVolume(
              uuid: $0.uuid, name: $0.name, roles: $0.roles, group: F.id(999),
              identifier: $0.identifier) : $0
        })
      assertRefusalPrefix(
        FakeRemovalDisk(snapshot, install: F.alarmInstall), "Found another system:")
      snapshot = F.alarm()
      snapshot.containers[index] = RemovalContainer(
        uuid: stub.uuid, storeUUID: stub.storeUUID,
        volumes: stub.volumes + [RemovalVolume(uuid: F.id(998), name: "VM", roles: ["VM"])])
      assertRefusalPrefix(
        FakeRemovalDisk(snapshot, install: F.alarmInstall), "Found another system:")
    }

    func testFrameMustBeISCThenBootedMacOSThenRecovery() {
      for index in [0, 1, 6] {
        var snapshot = F.converged()
        snapshot.partitions.remove(at: index)
        assertRefusalPrefix(FakeRemovalDisk(snapshot), "The internal disk doesn’t have the layout")
      }
      let original = F.converged()
      let booted = RemovalSnapshot(
        disk: original.disk, devicePath: original.devicePath, diskSize: original.diskSize,
        macOSStoreUUID: F.convergedInstall.stub, macOSContainerUUID: F.id(800),
        partitions: original.partitions, containers: original.containers)
      assertRefusalPrefix(FakeRemovalDisk(booted), "The internal disk doesn’t have the layout")
    }

    func testOverlappingOrDuplicatedPartitionsAreRefused() {
      var overlap = F.converged()
      let esp = overlap.partitions[3]
      overlap.partitions[3] = RemovalPartition(
        identifier: esp.identifier, uuid: esp.uuid, type: esp.type, offset: esp.offset - 4096,
        size: esp.size, name: esp.name)
      assertRefusalPrefix(FakeRemovalDisk(overlap), "The internal disk’s partition map")
      var duplicate = F.converged()
      duplicate.partitions.append(duplicate.partitions[3])
      assertRefusalPrefix(FakeRemovalDisk(duplicate), "The internal disk’s partition map")
    }

    // MARK: Evidence from the installation's files

    func testUnrelatedLinuxPartitionNextToAnInstallationIsNotErased() {
      let snapshot = F.snapshot(
        macOSSize: 400_000_000_000,
        [
          .part(F.uefiInstall.stub, "Apple_APFS", 2_499_805_184),
          .part(F.uefiInstall.esp, "EFI", 500_170_752, name: "EFI - UEFI"),
          .part(F.id(25), "Linux Filesystem", 30_000_000_000),
        ], installs: [F.uefiInstall])
      assertRefusal(
        FakeRemovalDisk(snapshot, install: F.uefiInstall),
        "Found the installation “UEFI boot” (disk0s3, disk0s4, disk0s5), but the installer record on its EFI partition doesn’t match the disk: disk0s5 wasn’t created by that installer. It can’t be confirmed as one installation, so nothing was changed."
      )
    }

    func testEveryEvidenceCheckRefusesWithItsReason() {
      let esp = F.alarmInstall.esp.lowercased()
      let other = F.id(77).lowercased()
      let cases: [(String, (inout RemovalInstallFiles) -> Void)] = [
        ("its EFI partition has no m1n1/boot.bin", { $0.espBootObject = nil }),
        ("its EFI partition has no readable asahi/stub_info.json", { $0.stubInfo = nil }),
        (
          "its EFI partition has no readable asahi/stub_info.json",
          { $0.stubInfo = Data("{not json".utf8) }
        ),
        (
          "the asahi/stub_info.json on its EFI partition names a different startup container",
          { $0.stubInfo = Data(#"{"vgid": "\#(F.id(601))"}"#.utf8) }
        ),
        (
          "its EFI partition has no installer record (asahi/installer.log)",
          { $0.installerLog = nil }
        ),
        (
          "the installer record on its EFI partition (asahi/installer.log) has entries that couldn’t be read",
          { $0.installerLog?.append(Data("\nINFO New partition: Partition(name='disk0s9'".utf8)) }
        ),
        (
          "the installer record on its EFI partition doesn’t match the disk: 1 partition it created is gone",
          {
            $0.installerLog?.append(
              Data(
                "\nINFO New partition: Partition(name='disk0s9', offset=1, size=1, free=False, type='Linux Filesystem', uuid='\(F.id(78))', desc=None)"
                  .utf8))
          }
        ),
        (
          "its startup container holds a full system (a Library folder), unlike a startup container made by the Asahi installer",
          { $0.stubHasLibrary = true }
        ),
        (
          "its startup container has no m1n1 boot object (Finish Installation.app)",
          { $0.stubBootObject = nil }
        ),
        (
          "the boot object in its startup container isn’t m1n1",
          {
            $0.stubBootObject = Data(
              "kernel STACKBOT chosen.asahi,efi-system-partition=\(esp)\n\0".utf8)
          }
        ),
        (
          "the m1n1 boot object in its startup container doesn’t point to this EFI partition",
          {
            $0.stubBootObject = Data(
              "##m1n1_ver##1\0STACKBOTchosen.asahi,efi-system-partition=\(other)\n\0".utf8)
          }
        ),
        (
          "the m1n1 boot object in its startup container doesn’t point to this EFI partition",
          {
            $0.stubBootObject = Data(
              "##m1n1_ver##1\0STACKBOTchosen.asahi,efi-system-partition=\(esp)\nchosen.asahi,efi-system-partition=\(esp)\n\0"
                .utf8)
          }
        ),
        (
          "the m1n1 boot object in its startup container doesn’t point to this EFI partition",
          {
            $0.stubBootObject = Data(
              "##m1n1_ver##1\0STACKBOTchosen.asahi,efi-system-partition=\(esp)".utf8)
          }
        ),
      ]
      for (reason, change) in cases {
        let disk = FakeRemovalDisk(F.alarm(), install: F.alarmInstall)
        change(&disk.files!)
        assertRefusal(
          disk,
          "Found the installation “Asahi Alarm Minimal” (disk0s3, disk0s4, disk0s5), but \(reason). It can’t be confirmed as one installation, so nothing was changed."
        )
      }
    }

    func testRealInstallerLogLinesFromTheM2Parse() {
      // Verbatim (cut after `info={`) from the M2 ESP's asahi/installer.log.
      let log = Data(
        """
        09-27 12:59 root         INFO     New partition: Partition(name='disk0s3', offset=675187716096, size=2499805184, free=False, type='Apple_APFS', uuid='A0913035-21F1-4CC5-B940-A26FD42BFA5C', desc=None, label='Omarchy', info={'AESHardware': True, 'APFSContainerReference': 'disk2', 'Bootable': True, 'BusProtocol': 'Apple Fabric', 'C
        09-27 12:59 root         INFO     New partition: Partition(name='disk0s4', offset=677687521280, size=524288000, free=False, type='EFI', uuid='BB18E021-9D1B-499C-8F25-849B7F5FCDCC', desc=None, label=None, info={'AESHardware': True, 'Bootable': False, 'BusProtocol': 'Apple Fabric', 'CanBeMadeBootable': False, 'CanBeMadeBootableReq
        09-27 12:59 root         INFO     New partition: Partition(name='disk0s5', offset=678211809280, size=2147483648, free=False, type='Linux Filesystem', uuid='E94DF227-99CE-438F-BE4B-9B7687487BDC', desc=None, label=None, info={'AESHardware': True, 'Bootable': False, 'BusProtocol': 'Apple Fabric', 'CanBeMadeBootable': False, 'CanBeM
        09-27 13:00 root         INFO     New partition: Partition(name='disk0s6', offset=680359292928, size=314827603968, free=False, type='Linux Filesystem', uuid='2CE86A5F-AF65-404E-A04C-B51092F45D8F', desc=None, label=None, info={'AESHardware': True, 'Bootable': False, 'BusProtocol': 'Apple Fabric', 'CanBeMadeBootable': False, 'CanB
        09-27 13:00 root         INFO       chosen.asahi,efi-system-partition=bb18e021-9d1b-499c-8f25-849b7f5fcdcc
        """.utf8)
      let install = F.convergedInstall
      XCTAssertEqual(
        RemovalEvidence.createdPartitions(log: log),
        [
          RemovalCreatedPartition(uuid: install.stub, type: "Apple_APFS"),
          RemovalCreatedPartition(uuid: install.esp, type: "EFI"),
          RemovalCreatedPartition(uuid: install.linux[0], type: "Linux Filesystem"),
          RemovalCreatedPartition(uuid: install.linux[1], type: "Linux Filesystem"),
        ])
    }

    func testTicketFromAnOlderHelperStillDecodes() throws {
      let json = #"{"id":"\#(UUID().uuidString)","reclaimBytes":1,"macOSBytesAfter":2}"#
      let ticket = try JSONDecoder().decode(OmarchyRemovalTicket.self, from: Data(json.utf8))
      XCTAssertEqual(ticket.kind, .installation)
      XCTAssertEqual(ticket.confirmation, OmarchyRemovalTicket.confirmation)
      XCTAssertTrue(ticket.deletions.isEmpty)
    }

    func testDuplicatedInstallerRecordIsUnreadable() {
      let log = Data(
        """
        New partition: Partition(name='disk0s3', offset=1, size=1, free=False, type='Apple_APFS', uuid='\(F.id(3))', desc=None)
        New partition: Partition(name='disk0s3', offset=1, size=1, free=False, type='Apple_APFS', uuid='\(F.id(3))', desc=None)
        """.utf8)
      XCTAssertNil(RemovalEvidence.createdPartitions(log: log))
      XCTAssertEqual(
        RemovalEvidence.createdPartitions(log: Data("no records here".utf8)), [])
    }

    func testUnreadableInstallationFilesAreReported() {
      let disk = FakeRemovalDisk(F.alarm(), install: F.alarmInstall)
      disk.files = nil
      assertRefusal(
        disk,
        "Found the installation “Asahi Alarm Minimal” (disk0s3, disk0s4, disk0s5), but its files couldn’t be checked: disk0s4 couldn’t be read without mounting it. Nothing was changed."
      )
    }

    // MARK: Startup disk

    func testPlanSetsMacOSAsTheStartupDiskFirstWhenItIsNot() throws {
      let cases: [(RemovalStartup, String)] = [
        (.other("Asahi Alarm Minimal"), "Your Mac starts up from “Asahi Alarm Minimal” now"),
        (.nextStartupOverride, "Replaces a one-time startup choice for the next restart"),
        (.unknown, "macOS couldn’t report which system your Mac starts up from"),
      ]
      for (startup, detail) in cases {
        let disk = FakeRemovalDisk(F.alarm(), install: F.alarmInstall)
        disk.startupState = startup
        let plan = try OmarchyRemovalPlan(disks: disk)
        XCTAssertEqual(plan.startup, startup)
        let ticket = plan.ticket(id: UUID())
        XCTAssertEqual(
          ticket.startupDisk,
          OmarchyRemovalItem(
            title: "Set macOS “Macintosh HD” as the startup disk", detail: detail, bytes: 0))
        XCTAssertEqual(ticket.deletions.count, 3)
        XCTAssertEqual(
          plan.summary,
          "Found “Asahi Alarm Minimal”. Removal first sets macOS as the startup disk, then permanently deletes “Asahi Alarm Minimal” and everything stored in it and returns its space to macOS."
        )
        XCTAssertTrue(disk.startupWrites.isEmpty, "planning is read-only")
      }
      let plan = try OmarchyRemovalPlan(disks: FakeRemovalDisk(F.alarm(), install: F.alarmInstall))
      XCTAssertNil(plan.startup)
      XCTAssertNil(plan.ticket(id: UUID()).startupDisk)
    }

    func testStartupDiskIsSetAndConfirmedBeforeAnythingIsDeleted() throws {
      let disk = FakeRemovalDisk(F.alarm(), install: F.alarmInstall)
      disk.startupState = .other("Asahi Alarm Minimal")
      let plan = try OmarchyRemovalPlan(disks: disk)
      disk.startupAfterSet = [.success(.macOS)]
      var journal = [String]()
      try OmarchyRemovalExecutor(disks: disk).execute(plan, authorization: authorization()) {
        journal.append($0)
      }
      XCTAssertEqual(disk.startupWrites.map(\.nextOnly), [false])
      XCTAssertEqual(disk.startupWrites.map(\.afterDeletion), [false])
      XCTAssertEqual(disk.startupPasswords, [Data("test-password".utf8)])
      XCTAssertEqual(disk.operations.first, "container:\(F.alarmInstall.stub)")
      XCTAssertEqual(journal.last, "complete")
    }

    func testOneTimeChoiceLeftAfterSettingIsReplacedForTheNextRestart() throws {
      let disk = FakeRemovalDisk(F.alarm(), install: F.alarmInstall)
      disk.startupState = .nextStartupOverride
      let plan = try OmarchyRemovalPlan(disks: disk)
      disk.startupAfterSet = [.success(.nextStartupOverride), .success(.macOS)]
      try OmarchyRemovalExecutor(disks: disk).execute(plan, authorization: authorization()) { _ in }
      XCTAssertEqual(disk.startupWrites.map(\.nextOnly), [false, true])
      XCTAssertEqual(disk.startupWrites.map(\.afterDeletion), [false, false])
      XCTAssertEqual(disk.operations.count, 4)
    }

    func testStartupDiskFailuresStopWithTheExactReasonAndDeleteNothing() throws {
      let refused = RemovalStartupRefusal(reason: "Failed to authenticate owner")
      let cases: [(RemovalStartup, [Result<RemovalStartup, RemovalStartupRefusal>], String)] = [
        (
          .other("Asahi Alarm Minimal"), [.failure(refused)],
          "macOS didn’t set “Macintosh HD” as the startup disk. It reported: “Failed to authenticate owner”. Nothing was deleted."
        ),
        (
          .other("Asahi Alarm Minimal"), [.success(.other("Asahi Alarm Minimal"))],
          "macOS set “Macintosh HD” as the startup disk, but afterwards it reports that your Mac starts up from “Asahi Alarm Minimal”. Nothing was deleted."
        ),
        (
          .unknown, [.success(.unknown)],
          "macOS set “Macintosh HD” as the startup disk, but afterwards it reports that it can’t tell which system your Mac starts up from. Nothing was deleted."
        ),
        (
          .nextStartupOverride, [.success(.nextStartupOverride), .success(.nextStartupOverride)],
          "macOS set “Macintosh HD” as the startup disk, but afterwards it reports that a one-time startup choice for the next restart is still set. Nothing was deleted."
        ),
        (
          .nextStartupOverride, [.success(.nextStartupOverride), .failure(refused)],
          "macOS set “Macintosh HD” as the startup disk, but afterwards it reports that a one-time startup choice for the next restart is still set, and replacing it didn’t work. It reported: “Failed to authenticate owner”. Nothing was deleted."
        ),
      ]
      for (before, results, message) in cases {
        let disk = FakeRemovalDisk(F.alarm(), install: F.alarmInstall)
        disk.startupState = before
        let plan = try OmarchyRemovalPlan(disks: disk)
        disk.startupAfterSet = results
        var journal = [String]()
        XCTAssertThrowsError(
          try OmarchyRemovalExecutor(disks: disk).execute(plan, authorization: authorization()) {
            journal.append($0)
          }
        ) { error in
          let failure = error as? RemovalFailure
          XCTAssertEqual(failure?.message, message)
          XCTAssertEqual(failure?.complete, true)
        }
        XCTAssertEqual(disk.startupWrites.count, results.count)
        XCTAssertTrue(disk.operations.isEmpty)
        XCTAssertTrue(journal.isEmpty)
      }
    }

    func testStopAfterTheStartupDiskChangedSaysSoUntilSomethingIsDeleted() throws {
      let disk = FakeRemovalDisk(F.alarm(), install: F.alarmInstall)
      disk.startupState = .other("Asahi Alarm Minimal")
      let plan = try OmarchyRemovalPlan(disks: disk)
      disk.startupAfterSet = [.success(.macOS)]
      XCTAssertThrowsError(
        try OmarchyRemovalExecutor(disks: disk).execute(plan, authorization: authorization()) {
          _ in throw RemovalFailure(message: "The removal record couldn’t be saved.")
        }
      ) { error in
        let failure = error as? RemovalFailure
        XCTAssertEqual(
          failure?.message,
          "The removal record couldn’t be saved. Your Mac now starts up from macOS “Macintosh HD”. Nothing was deleted."
        )
        XCTAssertEqual(failure?.complete, true)
      }
      XCTAssertTrue(disk.operations.isEmpty)

      let deleting = FakeRemovalDisk(F.alarm(), install: F.alarmInstall, failAt: 1)
      deleting.startupState = .other("Asahi Alarm Minimal")
      let next = try OmarchyRemovalPlan(disks: deleting)
      deleting.startupAfterSet = [.success(.macOS)]
      XCTAssertThrowsError(
        try OmarchyRemovalExecutor(disks: deleting).execute(next, authorization: authorization()) {
          _ in
        }
      ) { error in
        XCTAssertEqual((error as? RemovalFailure)?.message, "injected command failure")
        XCTAssertEqual((error as? RemovalFailure)?.complete, false)
      }
    }

    func testStartupChangedSinceReviewIsNotSetWithoutAFreshReview() throws {
      let changes: [(RemovalStartup?, RemovalStartup)] = [
        (nil, .other("Asahi Alarm Minimal")),
        (nil, .unknown),
        (.other("Asahi Alarm Minimal"), .other("Another System")),
        (.other("Asahi Alarm Minimal"), .nextStartupOverride),
        (.nextStartupOverride, .unknown),
      ]
      for (reviewed, live) in changes {
        let disk = FakeRemovalDisk(F.alarm(), install: F.alarmInstall)
        disk.startupState = reviewed ?? .macOS
        let plan = try OmarchyRemovalPlan(disks: disk)
        disk.afterPlanning = { $0.startupState = live }
        disk.startupAfterSet = [.success(.macOS)]
        XCTAssertThrowsError(
          try OmarchyRemovalExecutor(disks: disk).execute(plan, authorization: authorization()) {
            _ in
          }
        ) { error in
          XCTAssertEqual((error as? RemovalFailure)?.message, RemovalText.startupChanged)
        }
        XCTAssertTrue(disk.startupWrites.isEmpty)
        XCTAssertTrue(disk.operations.isEmpty)
      }
    }

    func testStartupFixedSinceReviewNeedsNoChange() throws {
      let disk = FakeRemovalDisk(F.alarm(), install: F.alarmInstall)
      disk.startupState = .other("Asahi Alarm Minimal")
      let plan = try OmarchyRemovalPlan(disks: disk)
      disk.afterPlanning = { $0.startupState = .macOS }
      try OmarchyRemovalExecutor(disks: disk).execute(plan, authorization: authorization()) { _ in }
      XCTAssertTrue(disk.startupWrites.isEmpty)
      XCTAssertEqual(disk.operations.count, 4)
    }

    func testStartupStepNeedsTheAdministratorAccount() throws {
      let disk = FakeRemovalDisk(F.alarm(), install: F.alarmInstall)
      disk.startupState = .other("Asahi Alarm Minimal")
      let plan = try OmarchyRemovalPlan(disks: disk)
      disk.startupAfterSet = [.success(.macOS)]
      XCTAssertThrowsError(try OmarchyRemovalExecutor(disks: disk).execute(plan) { _ in })
      XCTAssertTrue(disk.startupWrites.isEmpty)
      XCTAssertTrue(disk.operations.isEmpty)
    }

    func testTicketCarriesTheStartupStepToTheApp() throws {
      let disk = FakeRemovalDisk(F.alarm(), install: F.alarmInstall)
      disk.startupState = .other("Asahi Alarm Minimal")
      let ticket = try OmarchyRemovalPlan(disks: disk).ticket(id: UUID())
      let decoded = try JSONDecoder().decode(
        OmarchyRemovalTicket.self, from: JSONEncoder().encode(ticket))
      XCTAssertEqual(decoded, ticket)
      XCTAssertEqual(decoded.startupDisk?.title, "Set macOS “Macintosh HD” as the startup disk")
    }

    // MARK: Execution

    func testExecutionPreservesApplePartitionsAndGrowsMacOSByUUID() throws {
      let disk = FakeRemovalDisk()
      let original = try disk.snapshot()
      let plan = try OmarchyRemovalPlan(disks: disk)
      var journal = [String]()
      try OmarchyRemovalExecutor(disks: disk).execute(plan) { journal.append($0) }
      let install = F.convergedInstall
      XCTAssertEqual(
        disk.operations,
        ["container:\(install.stub)", "erase:\(install.esp)"] + install.linux.map { "erase:\($0)" }
          + ["grow:\(F.mac)"])
      let result = try disk.snapshot()
      XCTAssertEqual(result.partitions.first, original.partitions.first)
      XCTAssertEqual(result.partitions.last, original.partitions.last)
      XCTAssertEqual(result.partitions.count, 3)
      XCTAssertEqual(result.partitions[1].size, plan.targetMacOSBytes)
      XCTAssertEqual(journal.last, "complete")
    }

    func testOlderOmarchyMacInstallIsRemovedAndReclaimed() throws {
      let disk = FakeRemovalDisk(F.alarm(), install: F.alarmInstall)
      let plan = try OmarchyRemovalPlan(disks: disk)
      try OmarchyRemovalExecutor(disks: disk).execute(plan) { _ in }
      XCTAssertEqual(
        disk.operations,
        [
          "container:\(F.alarmInstall.stub)", "erase:\(F.alarmInstall.esp)",
          "erase:\(F.alarmInstall.linux[0])", "grow:\(F.mac)",
        ])
      XCTAssertEqual(disk.state.partitions.map(\.uuid), [F.isc, F.mac, F.recovery])
      XCTAssertEqual(disk.state.partitions[1].size, 494_384_793_600)
    }

    func testFreeSpaceOnlyOnlyGrowsMacOS() throws {
      let disk = FakeRemovalDisk(F.freeSpaceOnly(), install: nil)
      let plan = try OmarchyRemovalPlan(disks: disk)
      var journal = [String]()
      try OmarchyRemovalExecutor(disks: disk).execute(plan) { journal.append($0) }
      XCTAssertEqual(disk.operations, ["grow:\(F.mac)"])
      XCTAssertEqual(journal, ["returning-space-to-macos", "complete"])
      XCTAssertEqual(disk.state.partitions[1].size, 494_384_793_600)
    }

    func testFreeSpaceGrowthLimitAtExecutionLeavesNoJournal() throws {
      let disk = FakeRemovalDisk(F.freeSpaceOnly(), install: nil)
      let plan = try OmarchyRemovalPlan(disks: disk)
      disk.limitOverride = 461_584_287_744
      var journal = [String]()
      XCTAssertThrowsError(
        try OmarchyRemovalExecutor(disks: disk).execute(plan) { journal.append($0) })
      XCTAssertTrue(journal.isEmpty)
      XCTAssertTrue(disk.operations.isEmpty)
    }

    func testChangedFilesOrStartupSinceReviewStopBeforeAnyChange() throws {
      let changes: [(FakeRemovalDisk) -> Void] = [
        { $0.files?.installerLog?.append(Data("\nmore".utf8)) },
        { $0.files?.stubHasLibrary = true },
        { $0.startupState = .nextStartupOverride },
      ]
      for change in changes {
        let disk = FakeRemovalDisk(F.alarm(), install: F.alarmInstall)
        let plan = try OmarchyRemovalPlan(disks: disk)
        disk.afterPlanning = change
        var journal = [String]()
        XCTAssertThrowsError(
          try OmarchyRemovalExecutor(disks: disk).execute(plan) { journal.append($0) })
        XCTAssertTrue(disk.operations.isEmpty)
        XCTAssertTrue(journal.isEmpty)
      }
    }

    func testEveryCommandFailureStopsWithoutReplayingOrGrowing() throws {
      for failure in 1...5 {
        let disk = FakeRemovalDisk(failAt: failure)
        let plan = try OmarchyRemovalPlan(disks: disk)
        XCTAssertThrowsError(try OmarchyRemovalExecutor(disks: disk).execute(plan) { _ in })
        XCTAssertEqual(disk.operations.count, failure)
        XCTAssertEqual(disk.state.partitions[0].uuid, F.isc)
        XCTAssertEqual(disk.state.partitions.last?.uuid, F.recovery)
        XCTAssertEqual(disk.state.partitions[1].size, plan.macOS.size)
      }
    }

    func testGrowthLimitAfterDeletionStopsBeforeResizing() throws {
      let disk = FakeRemovalDisk(F.alarm(), install: F.alarmInstall)
      let plan = try OmarchyRemovalPlan(disks: disk)
      disk.limitOverride = 470_000_000_000
      XCTAssertThrowsError(try OmarchyRemovalExecutor(disks: disk).execute(plan) { _ in })
      XCTAssertEqual(disk.operations.count, 3)
      XCTAssertFalse(disk.operations.contains("grow:\(F.mac)"))
    }

    func testJournalFailurePreventsFirstMutation() throws {
      let disk = FakeRemovalDisk()
      let plan = try OmarchyRemovalPlan(disks: disk)
      XCTAssertThrowsError(
        try OmarchyRemovalExecutor(disks: disk).execute(plan) { _ in
          throw RemovalFailure(message: "journal full")
        })
      XCTAssertTrue(disk.operations.isEmpty)
    }

    func testChangedMacOSOrRecoveryIdentityStopsBeforeDeletion() throws {
      for index in [0, 1, 6] {
        let disk = FakeRemovalDisk()
        let plan = try OmarchyRemovalPlan(disks: disk)
        disk.state.partitions[index].size += 4096
        XCTAssertThrowsError(try OmarchyRemovalExecutor(disks: disk).execute(plan) { _ in })
        XCTAssertTrue(disk.operations.isEmpty)
      }
    }

    func testSuccessfulCommandWithoutActualGrowthIsNotSuccess() throws {
      let disk = FakeRemovalDisk(skipGrowth: true)
      let plan = try OmarchyRemovalPlan(disks: disk)
      var journal = [String]()
      XCTAssertThrowsError(
        try OmarchyRemovalExecutor(disks: disk).execute(plan) { journal.append($0) })
      XCTAssertFalse(journal.contains("complete"))
    }

    func testRenumberedBSDIdentifiersStillMatchUUIDBoundPlan() throws {
      let plan = try OmarchyRemovalPlan(disks: FakeRemovalDisk())
      var changed = F.converged()
      changed.partitions = changed.partitions.enumerated().map { index, part in
        RemovalPartition(
          identifier: "disk0s\(index + 20)", uuid: part.uuid, type: part.type, offset: part.offset,
          size: part.size, name: part.name)
      }
      XCTAssertNoThrow(try plan.validate(changed, removed: []))
      XCTAssertEqual(try plan.live(plan.members[0], in: changed).identifier, "disk0s22")
    }

    // MARK: Helper service

    func testServerEnforcesExactPhraseAndSingleUseTicket() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let disk = FakeRemovalDisk()
      let server = server(root: root, disk: disk)
      let inspection = try await server.removal(ticketID: nil, confirmation: "", authorization: nil)
      let ticket = try XCTUnwrap(inspection.ticket)
      XCTAssertEqual(ticket.kind, .installation)
      XCTAssertEqual(ticket.deletions.count, 4)
      for phrase in [
        "", "delete omarchy", "Delete omarchy installation and data",
        OmarchyRemovalTicket.confirmation + " ", OmarchyRemovalTicket.freeSpaceConfirmation,
      ] {
        do {
          _ = try await server.removal(
            ticketID: ticket.id, confirmation: phrase, authorization: authorization())
          XCTFail("Incorrect phrase accepted")
        } catch {}
        XCTAssertTrue(disk.operations.isEmpty)
      }
      let freshReply = try await server.removal(
        ticketID: nil, confirmation: "", authorization: nil)
      let fresh = try XCTUnwrap(freshReply.ticket)
      let result = try await server.removal(
        ticketID: fresh.id, confirmation: OmarchyRemovalTicket.confirmation,
        authorization: authorization())
      XCTAssertTrue(result.completed, result.message)
      XCTAssertEqual(
        result.message,
        "“Omarchy” and its data have been removed. The freed space is now part of macOS.")
      do {
        _ = try await server.removal(
          ticketID: fresh.id, confirmation: OmarchyRemovalTicket.confirmation,
          authorization: authorization())
        XCTFail("Replayed ticket accepted")
      } catch {}
      XCTAssertEqual(disk.operations.count, 5)
    }

    func testSuccessfulRemovalRetiresInstallJournalsSoTheSamePlanRunsAgain() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let journals = root.appendingPathComponent("execution-journals", isDirectory: true)
      try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: false)
      let finished = Data(#"{"completion":"awaiting_recovery"}"#.utf8)
      try finished.write(to: journals.appendingPathComponent("abc.jsonl"))
      let service = server(root: root, disk: FakeRemovalDisk())
      let inspection = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil)
      let ticket = try XCTUnwrap(inspection.ticket)
      let result = try await service.removal(
        ticketID: ticket.id, confirmation: ticket.confirmation, authorization: authorization())
      XCTAssertTrue(result.completed, result.message)
      XCTAssertEqual(
        result.message,
        "“Omarchy” and its data have been removed. The freed space is now part of macOS.")
      XCTAssertFalse(FileManager.default.fileExists(atPath: journals.path))
      let kept = root.appendingPathComponent(
        "retired-execution-journals/\(ticket.id.uuidString)/abc.jsonl")
      XCTAssertEqual(try Data(contentsOf: kept), finished)
      let record = root.appendingPathComponent("removal-\(ticket.id.uuidString).json")
      XCTAssertEqual(try recordedRetirement(record), true, "set aside, durably recorded")
      let finalization = await service.removalFinalization(ticketID: ticket.id)
      XCTAssertEqual(finalization, .finalized)
    }

    func testStoppingAfterMacOSGrewButBeforeCompleteKeepsInstallingBlocked() async throws {
      // Crash window: macOS took the space back, but the helper stopped
      // before it recorded "complete". The app must not call that done.
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let journals = try makeInstallJournals(root)
      let id = UUID()
      try writeRecord(root, id, phase: "returning-space-to-macos", retired: false)
      let service = server(root: root, disk: FakeRemovalDisk())

      let finalization = await service.removalFinalization(ticketID: id)
      XCTAssertEqual(finalization, .unfinished)
      let error = await submitError(service)
      XCTAssertEqual(error as? ClosedEngineHelperError, .earlierRemovalUnfinished)
      XCTAssertTrue(FileManager.default.fileExists(atPath: journals.path), "nothing is guessed")
    }

    func testStoppingAfterCompleteButBeforeSettingJournalsAsideIsSettledFirst() async throws {
      // Crash window: "complete" is recorded, the install journals are not
      // set aside yet. Left alone, a reinstall at the same size would find
      // its old journal complete and skip installing.
      for asks in ["app", "install"] {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journals = try makeInstallJournals(root)
        let id = UUID()
        let record = try writeRecord(root, id, phase: "complete", retired: false)
        let service = server(root: root, disk: FakeRemovalDisk())

        if asks == "app" {
          let finalization = await service.removalFinalization(ticketID: id)
          XCTAssertEqual(finalization, .finalized)
        } else {
          let error = await submitError(service)
          XCTAssertNil(error as? ClosedEngineHelperError, "the install passes the gate")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: journals.path), asks)
        XCTAssertTrue(
          FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
              "retired-execution-journals/\(id.uuidString)/abc.jsonl"
            ).path), asks)
        XCTAssertEqual(try recordedRetirement(record), true, asks)
      }
    }

    func testFailingToSetJournalsAsideBlocksASameSizeReinstallUntilItWorks() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let journals = try makeInstallJournals(root)
      // A file where the retired journals go makes moving them fail.
      let obstacle = root.appendingPathComponent("retired-execution-journals")
      try Data("x".utf8).write(to: obstacle)
      let service = server(root: root, disk: FakeRemovalDisk())
      let inspection = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil)
      let ticket = try XCTUnwrap(inspection.ticket)

      let result = try await service.removal(
        ticketID: ticket.id, confirmation: ticket.confirmation, authorization: authorization())
      XCTAssertTrue(result.completed, "the disks are done")
      XCTAssertTrue(result.message.contains("won’t install until that works"), result.message)
      let record = root.appendingPathComponent("removal-\(ticket.id.uuidString).json")
      XCTAssertEqual(try recordedRetirement(record), false)

      // The same-size reinstall is refused, not handed the old journal.
      let refused = await submitError(service)
      XCTAssertEqual(refused as? ClosedEngineHelperError, .earlierInstallRecordUncleared)
      let finalization = await service.removalFinalization(ticketID: ticket.id)
      XCTAssertEqual(finalization, .installRecordUncleared)
      do {
        _ = try await service.removal(ticketID: nil, confirmation: "", authorization: nil)
        XCTFail("a new removal must not start either")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains("set aside"), "\(error)")
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: journals.path))

      // Once moving works, the next install sets them aside and goes ahead.
      try FileManager.default.removeItem(at: obstacle)
      let next = await submitError(service)
      XCTAssertNil(next as? ClosedEngineHelperError, "\(String(describing: next))")
      XCTAssertFalse(FileManager.default.fileExists(atPath: journals.path))
      XCTAssertEqual(try recordedRetirement(record), true)
    }

    func testCompleteRecordsFromEarlierVersionsSetAsideOnlyJournalsThatPredateThem() async throws {
      // Earlier versions recorded nothing about the journals, and an install
      // may have run since. Journals created before the record are the
      // removed installation's and go; later ones belong to a later install.
      enum Case { case older, newerDirectory, mixed }
      for scenario in [Case.older, .newerDirectory, .mixed] {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let record = root.appendingPathComponent("removal-\(id.uuidString).json")
        let old = #"{"plan":{"members":[],"targetMacOSBytes":1},"phase":"complete"}"#
        let earlier = Date(timeIntervalSinceNow: -3600)
        let journals = root.appendingPathComponent("execution-journals")
        let removedInstall = journals.appendingPathComponent("abc.jsonl")
        let laterInstall = journals.appendingPathComponent("later.jsonl")
        switch scenario {
        case .older:
          _ = try makeInstallJournals(root)
          try Data(old.utf8).write(to: record)
        case .newerDirectory:
          try Data(old.utf8).write(to: record)
          try FileManager.default.setAttributes(
            [.modificationDate: earlier], ofItemAtPath: record.path)
          _ = try makeInstallJournals(root)
        case .mixed:
          // The old helper failed to set journal abc aside; a later attempt
          // at another size added its own and stopped. A retry at abc's size
          // must not find abc complete and skip installing.
          _ = try makeInstallJournals(root)
          try FileManager.default.setAttributes(
            [.creationDate: earlier.addingTimeInterval(-60)], ofItemAtPath: removedInstall.path)
          try Data(old.utf8).write(to: record)
          try FileManager.default.setAttributes(
            [.modificationDate: earlier], ofItemAtPath: record.path)
          try Data("{}".utf8).write(to: laterInstall)
          let handle = try FileHandle(forWritingTo: removedInstall)
          try handle.seekToEnd()
          try handle.write(contentsOf: Data("\n".utf8))
          try handle.close()
        }
        let service = server(root: root, disk: FakeRemovalDisk())
        let error = await submitError(service)
        XCTAssertNil(error as? ClosedEngineHelperError, "\(String(describing: error))")
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        let archived = root.appendingPathComponent(
          "retired-execution-journals/\(id.uuidString)/abc.jsonl")
        switch scenario {
        case .older:
          XCTAssertFalse(exists(journals))
          XCTAssertTrue(exists(archived))
          XCTAssertEqual(try recordedRetirement(record), true)
        case .newerDirectory:
          XCTAssertTrue(exists(removedInstall), "a later install's journal stays")
          XCTAssertEqual(try recordedRetirement(record), true, "nothing of its own was left")
        case .mixed:
          XCTAssertFalse(exists(removedInstall), "the removed installation's journal goes")
          XCTAssertTrue(exists(archived))
          XCTAssertTrue(exists(laterInstall), "the later attempt's journal stays")
          XCTAssertEqual(try recordedRetirement(record), true)
        }
      }
    }

    func testARetryRedoesTheSyncThatFailedAfterTheJournalsMoved() throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let journals = try makeInstallJournals(root)
      let id = UUID()
      let record = try writeRecord(root, id, phase: "complete", retired: false)
      struct SyncFailed: Error {}

      XCTAssertThrowsError(
        try settleCompletedRemoval(record, in: root) { directory in
          if directory.lastPathComponent == "retired-execution-journals" { throw SyncFailed() }
          try synchronizeDirectory(directory)
        }
      ) { XCTAssertEqual($0 as? EarlierRemovalProblem, .installRecordUncleared) }
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: journals.path), "the rename went through")
      XCTAssertEqual(try recordedRetirement(record), false)

      var synchronized: [String] = []
      try settleCompletedRemoval(record, in: root) { directory in
        synchronized.append(directory.lastPathComponent)
        try synchronizeDirectory(directory)
      }
      XCTAssertTrue(synchronized.contains(id.uuidString), "\(synchronized)")
      XCTAssertTrue(synchronized.contains("retired-execution-journals"), "\(synchronized)")
      XCTAssertEqual(try recordedRetirement(record), true)
    }

    func testARetryOfAnEarlierVersionsRecordRedoesTheSyncThatFailed() throws {
      // Legacy records are judged by which journals are left, so a retry
      // after a failed sync may find none to move: it still syncs and marks.
      for (mixed, failing) in [(false, "retired-execution-journals"), (true, "execution-journals")]
      {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journals = try makeInstallJournals(root)
        let id = UUID()
        let record = try writeRecord(root, id, phase: "complete", retired: nil)
        let laterInstall = journals.appendingPathComponent("later.jsonl")
        if mixed {
          let earlier = Date(timeIntervalSinceNow: -3600)
          try FileManager.default.setAttributes(
            [.creationDate: earlier.addingTimeInterval(-60)],
            ofItemAtPath: journals.appendingPathComponent("abc.jsonl").path)
          try FileManager.default.setAttributes(
            [.modificationDate: earlier], ofItemAtPath: record.path)
          try Data("{}".utf8).write(to: laterInstall)
        }
        struct SyncFailed: Error {}

        XCTAssertThrowsError(
          try settleCompletedRemoval(record, in: root) { directory in
            if directory.lastPathComponent == failing { throw SyncFailed() }
            try synchronizeDirectory(directory)
          }
        ) { XCTAssertEqual($0 as? EarlierRemovalProblem, .installRecordUncleared) }
        XCTAssertFalse(
          FileManager.default.fileExists(atPath: journals.appendingPathComponent("abc.jsonl").path),
          "the move went through")
        XCTAssertEqual(try recordedRetirement(record), nil)

        var synchronized: [String] = []
        try settleCompletedRemoval(record, in: root) { directory in
          synchronized.append(directory.lastPathComponent)
          try synchronizeDirectory(directory)
        }
        XCTAssertTrue(synchronized.contains(failing), "\(synchronized)")
        XCTAssertTrue(synchronized.contains(id.uuidString), "\(synchronized)")
        XCTAssertEqual(try recordedRetirement(record), true)
        XCTAssertEqual(FileManager.default.fileExists(atPath: laterInstall.path), mixed)
      }
    }

    func testAskingAboutAnUnknownRemovalOrWhileBusyClaimsNothing() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let work = HelperWorkState()
      let service = ClosedEngineHelperServer(
        workingDirectory: root, executor: UnusedRemovalHandoffExecutor(),
        credentialValidator: RemovalCredentials(reject: false), removalDisks: FakeRemovalDisk(),
        removalAdminValidator: { _ in }, work: work)
      let id = UUID()
      try writeRecord(root, id, phase: "complete", retired: true)
      let unknown = await service.removalFinalization(ticketID: UUID())
      XCTAssertEqual(unknown, .unknown)
      try work.beginJob()
      let busy = await service.removalFinalization(ticketID: id)
      XCTAssertEqual(busy, .busy)
      work.endJob()
      let endpoint = ClosedEngineXPCServiceEndpoint(server: service)
      let answers = await withCheckedContinuation { c in
        endpoint.removalFinalization(ticket: id.uuidString) { c.resume(returning: $0) }
      }
      XCTAssertEqual(answers, "finalized")
      let malformed = await withCheckedContinuation { c in
        endpoint.removalFinalization(ticket: "not-a-ticket") { c.resume(returning: $0) }
      }
      XCTAssertEqual(malformed, "unknown")
    }

    func testOnlyACompletedRemovalUninstallsTheHelper() async throws {
      for (failAt, uninstalls) in [(Int?.none, 1), (3, 0)] {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uninstaller = RecordingSelfUninstaller()
        let service = ClosedEngineHelperServer(
          workingDirectory: root, executor: UnusedRemovalHandoffExecutor(),
          credentialValidator: RemovalCredentials(reject: false),
          removalDisks: failAt.map { FakeRemovalDisk(failAt: $0) } ?? FakeRemovalDisk(),
          removalAdminValidator: { _ in }, selfUninstaller: uninstaller)
        let inspection = try await service.removal(
          ticketID: nil, confirmation: "", authorization: nil)
        XCTAssertEqual(uninstaller.calls, 0, "inspecting never uninstalls")
        let ticket = try XCTUnwrap(inspection.ticket)
        let result = try await service.removal(
          ticketID: ticket.id, confirmation: ticket.confirmation, authorization: authorization())
        XCTAssertEqual(result.completed, uninstalls == 1, result.message)
        XCTAssertEqual(uninstaller.calls, uninstalls, "failAt \(String(describing: failAt))")
      }
    }

    func testACompletedRemovalRetiresTheHelperBeforeItTakesMoreWork() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let service = ClosedEngineHelperServer(
        workingDirectory: root, executor: UnusedRemovalHandoffExecutor(),
        credentialValidator: RemovalCredentials(reject: false), removalDisks: FakeRemovalDisk(),
        removalAdminValidator: { _ in }, selfUninstaller: RecordingSelfUninstaller())
      let endpoint = ClosedEngineXPCServiceEndpoint(server: service, version: "28")
      let inspection = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil)
      let ticket = try XCTUnwrap(inspection.ticket)
      let before = await withCheckedContinuation { c in endpoint.ping { c.resume(returning: $0) } }
      XCTAssertTrue(before)

      let result = try await service.removal(
        ticketID: ticket.id, confirmation: ticket.confirmation, authorization: authorization())
      XCTAssertTrue(result.completed, result.message)

      let retiring = await service.isRetiring
      XCTAssertTrue(retiring)
      do {
        _ = try await service.removal(ticketID: nil, confirmation: "", authorization: nil)
        XCTFail("a retiring helper must refuse new work")
      } catch let error as ClosedEngineHelperError {
        XCTAssertEqual(error, .retiring)
      }
      let ping = await withCheckedContinuation { c in endpoint.ping { c.resume(returning: $0) } }
      let version = await withCheckedContinuation { c in
        endpoint.helperVersion { c.resume(returning: $0) }
      }
      XCTAssertFalse(ping, "a retiring helper reads as gone, so the app sets up a fresh one")
      XCTAssertEqual(version, "")
    }

    func testACompletedRemovalKeepsAPackageInstalledHelperTakingWork() async throws {
      // Only the installer package can register this helper again, so it
      // stays and the next install works without running the package.
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let uninstaller = RecordingSelfUninstaller(uninstallsAfterRemoval: false)
      let service = ClosedEngineHelperServer(
        workingDirectory: root, executor: UnusedRemovalHandoffExecutor(),
        credentialValidator: RemovalCredentials(reject: false), removalDisks: FakeRemovalDisk(),
        removalAdminValidator: { _ in }, selfUninstaller: uninstaller)
      let endpoint = ClosedEngineXPCServiceEndpoint(server: service, version: "28")
      let inspection = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil)
      let ticket = try XCTUnwrap(inspection.ticket)

      let result = try await service.removal(
        ticketID: ticket.id, confirmation: ticket.confirmation, authorization: authorization())
      XCTAssertTrue(result.completed, result.message)

      XCTAssertEqual(uninstaller.calls, 0)
      XCTAssertFalse(service.isRetiring)
      let ping = await withCheckedContinuation { c in endpoint.ping { c.resume(returning: $0) } }
      let version = await withCheckedContinuation { c in
        endpoint.helperVersion { c.resume(returning: $0) }
      }
      XCTAssertTrue(ping, "the app keeps using this helper")
      XCTAssertEqual(version, "28")
      do {
        // The disks now hold nothing to remove, so planning itself refuses;
        // what matters is that the helper took the request.
        _ = try await service.removal(ticketID: nil, confirmation: "", authorization: nil)
      } catch let error as ClosedEngineHelperError {
        XCTFail("the helper must still take work, got \(error)")
      } catch {}
    }

    func testHelperErrorCodesKeepTheirValuesAcrossVersions() {
      // XPC carries these as NSError codes between app and helper builds. Swift
      // numbers cases with a value first, then the rest in order; new cases
      // go last so none of these ever changes.
      let codes: [(ClosedEngineHelperError, Int)] = [
        (.unsupportedDevice("x"), 0), (.busy, 1), (.invalidOperation, 2),
        (.invalidMachineOwnerCredentials, 3), (.invalidClientRequirement, 4),
        (.transcriptDeviceMismatch, 5), (.transcriptIncomplete, 6), (.transcriptPlanMismatch, 7),
        (.installConfPlanIncomplete, 8), (.installConfTargetMismatch, 9),
        (.installConfReplay, 10), (.retiring, 11), (.beingReplaced, 12),
        (.earlierRemovalUnfinished, 13), (.earlierInstallRecordUncleared, 14),
      ]
      for (error, code) in codes {
        XCTAssertEqual((error as NSError).code, code, "\(error)")
      }
    }

    func testFailedRemovalKeepsInstallJournals() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let journals = root.appendingPathComponent("execution-journals", isDirectory: true)
      try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: false)
      let service = server(root: root, disk: FakeRemovalDisk(failAt: 3))
      let inspection = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil)
      let result = try await service.removal(
        ticketID: XCTUnwrap(inspection.ticket).id, confirmation: OmarchyRemovalTicket.confirmation,
        authorization: authorization())
      XCTAssertFalse(result.completed)
      XCTAssertTrue(FileManager.default.fileExists(atPath: journals.path))
    }

    func testServerFreeSpaceNeedsItsOwnPhraseAndNeverClaimsRemoval() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let disk = FakeRemovalDisk(F.freeSpaceOnly(), install: nil)
      let service = server(root: root, disk: disk)
      let firstReply = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil)
      let first = try XCTUnwrap(firstReply.ticket)
      XCTAssertEqual(first.kind, .freeSpace)
      do {
        _ = try await service.removal(
          ticketID: first.id, confirmation: OmarchyRemovalTicket.confirmation,
          authorization: authorization())
        XCTFail("Deletion phrase accepted for free space")
      } catch {}
      let secondReply = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil)
      let second = try XCTUnwrap(secondReply.ticket)
      let result = try await service.removal(
        ticketID: second.id, confirmation: "return free space to macos",
        authorization: authorization())
      XCTAssertTrue(result.completed)
      XCTAssertEqual(result.message, "The free space is now part of macOS.")
      XCTAssertEqual(disk.operations, ["grow:\(F.mac)"])
    }

    func testServerFreeSpaceResizeFailureDoesNotMentionRemoval() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let disk = FakeRemovalDisk(F.freeSpaceOnly(), install: nil, failAt: 1)
      let service = server(root: root, disk: disk)
      let ticketReply = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil)
      let ticket = try XCTUnwrap(ticketReply.ticket)
      let result = try await service.removal(
        ticketID: ticket.id, confirmation: ticket.confirmation, authorization: authorization())
      XCTAssertFalse(result.completed)
      XCTAssertTrue(result.requiresReview)
      XCTAssertTrue(result.message.hasPrefix("macOS couldn’t confirm it took the free space."))
      XCTAssertFalse(result.message.contains("Omarchy"))
    }

    func testServerRefusalCarriesTheExactFinding() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let service = server(root: root, disk: FakeRemovalDisk(F.windows(), install: nil))
      do {
        _ = try await service.removal(ticketID: nil, confirmation: "", authorization: nil)
        XCTFail("Windows layout accepted")
      } catch {
        XCTAssertTrue((error as? RemovalFailure)?.message.contains("“BOOTCAMP”") == true)
      }
    }

    func testCredentialAndAdministratorRejectionPrecedeDeletion() async throws {
      for rejectAdmin in [false, true] {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = FakeRemovalDisk()
        let service = ClosedEngineHelperServer(
          workingDirectory: root, executor: UnusedRemovalHandoffExecutor(),
          credentialValidator: RemovalCredentials(reject: !rejectAdmin), removalDisks: disk,
          removalAdminValidator: { _ in
            if rejectAdmin { throw RemovalFailure(message: "not administrator") }
          })
        let inspection = try await service.removal(
          ticketID: nil, confirmation: "", authorization: nil)
        let result = try await service.removal(
          ticketID: XCTUnwrap(inspection.ticket).id,
          confirmation: OmarchyRemovalTicket.confirmation, authorization: authorization())
        XCTAssertFalse(result.completed)
        XCTAssertTrue(disk.operations.isEmpty)
      }
    }

    func testServerSetsTheStartupDiskWithTheAccountFromTheSheet() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let disk = FakeRemovalDisk()
      disk.startupState = .other("Omarchy")
      disk.startupAfterSet = [.success(.macOS)]
      let service = server(root: root, disk: disk)
      let inspection = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil)
      let ticket = try XCTUnwrap(inspection.ticket)
      XCTAssertEqual(ticket.startupDisk?.detail, "Your Mac starts up from “Omarchy” now")
      let result = try await service.removal(
        ticketID: ticket.id, confirmation: ticket.confirmation, authorization: authorization())
      XCTAssertTrue(result.completed, result.message)
      XCTAssertEqual(disk.startupPasswords, [Data("test-password".utf8)])
      XCTAssertEqual(disk.operations.count, 5)
    }

    func testServerStartupFailureSaysNothingWasDeletedAndKeepsNoRecord() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let disk = FakeRemovalDisk()
      disk.startupState = .other("Omarchy")
      disk.startupAfterSet = [
        .failure(RemovalStartupRefusal(reason: "Failed to authenticate owner"))
      ]
      let service = server(root: root, disk: disk)
      let inspection = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil)
      let result = try await service.removal(
        ticketID: XCTUnwrap(inspection.ticket).id, confirmation: OmarchyRemovalTicket.confirmation,
        authorization: authorization())
      XCTAssertFalse(result.completed)
      XCTAssertFalse(result.requiresReview)
      XCTAssertEqual(
        result.message,
        "macOS didn’t set “Macintosh HD” as the startup disk. It reported: “Failed to authenticate owner”. Nothing was deleted."
      )
      XCTAssertTrue(disk.operations.isEmpty)
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
      let next = try await service.removal(ticketID: nil, confirmation: "", authorization: nil)
      XCTAssertNotNil(next.ticket, "a refused startup change doesn't block the next review")
    }

    func testInterruptedJournalBlocksNewRequestsAfterHelperRestart() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let disk = FakeRemovalDisk(failAt: 3)
      let first = server(root: root, disk: disk)
      let inspection = try await first.removal(ticketID: nil, confirmation: "", authorization: nil)
      let result = try await first.removal(
        ticketID: XCTUnwrap(inspection.ticket).id, confirmation: OmarchyRemovalTicket.confirmation,
        authorization: authorization())
      XCTAssertFalse(result.completed)
      XCTAssertTrue(result.message.contains("some data in “Omarchy” may already be deleted"))
      let restarted = server(root: root, disk: disk)
      do {
        _ = try await restarted.removal(ticketID: nil, confirmation: "", authorization: nil)
        XCTFail("Interrupted removal was ignored")
      } catch { XCTAssertTrue(error.localizedDescription.contains("earlier removal")) }
    }

    func testCompleteJournalFromEarlierVersionDoesNotBlock() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let old = #"{"plan":{"members":[],"targetMacOSBytes":1},"phase":"complete"}"#
      try Data(old.utf8).write(to: root.appendingPathComponent("removal-\(UUID()).json"))
      let service = server(root: root, disk: FakeRemovalDisk())
      let inspection = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil)
      XCTAssertNotNil(inspection.ticket)
      try Data(#"{"phase":"removing-x"}"#.utf8).write(
        to: root.appendingPathComponent("removal-\(UUID()).json"))
      do {
        _ = try await service.removal(ticketID: nil, confirmation: "", authorization: nil)
        XCTFail("Interrupted removal was ignored")
      } catch { XCTAssertTrue(error.localizedDescription.contains("earlier removal")) }
    }

    func testResizeFailureReportsDataRemovedWithoutSuccess() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let disk = FakeRemovalDisk(failAt: 5)
      let service = server(root: root, disk: disk)
      let inspection = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil)
      let result = try await service.removal(
        ticketID: XCTUnwrap(inspection.ticket).id, confirmation: OmarchyRemovalTicket.confirmation,
        authorization: authorization())
      XCTAssertFalse(result.completed)
      XCTAssertTrue(result.message.contains("“Omarchy” was removed"))
      XCTAssertFalse(result.message.contains("No disk changes"))
      let files = try FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil)
      let data = try Data(contentsOf: XCTUnwrap(files.first))
      let text = String(decoding: data, as: UTF8.self)
      XCTAssertFalse(text.contains("test-password"))
      XCTAssertFalse(text.contains("Test Owner"))
    }

    func testHelperRejectsForeignTicketBeforeAuthenticationOrDeletion() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let disk = FakeRemovalDisk()
      let service = server(root: root, disk: disk)
      _ = try await service.removal(ticketID: nil, confirmation: "", authorization: nil)
      do {
        _ = try await service.removal(
          ticketID: UUID(), confirmation: OmarchyRemovalTicket.confirmation,
          authorization: authorization())
        XCTFail("Foreign ticket accepted")
      } catch {}
      XCTAssertTrue(disk.operations.isEmpty)
    }

    func testInstallAndAnotherRemovalAreBlockedWhileRemoving() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let disk = BlockingRemovalDisk()
      let service = ClosedEngineHelperServer(
        workingDirectory: root, executor: UnusedRemovalHandoffExecutor(),
        credentialValidator: RemovalCredentials(reject: false), removalDisks: disk,
        removalAdminValidator: { _ in })
      let inspection = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil)
      let ticket = try XCTUnwrap(inspection.ticket)
      let auth = try authorization()
      let task = Task {
        try await service.removal(
          ticketID: ticket.id, confirmation: OmarchyRemovalTicket.confirmation, authorization: auth)
      }
      let entered = await Task.detached { disk.waitUntilEntered() }.value
      defer { disk.resume.signal() }
      XCTAssertTrue(entered)
      do {
        _ = try await service.removal(ticketID: nil, confirmation: "", authorization: nil)
        XCTFail("Concurrent removal accepted")
      } catch { XCTAssertEqual(error as? ClosedEngineHelperError, .busy) }
      do {
        _ = try await service.submit(packageDirectory: .standardInput, authorization: auth)
        XCTFail("Concurrent install accepted")
      } catch { XCTAssertEqual(error as? ClosedEngineHelperError, .busy) }
      disk.resume.signal()
      let result = try await task.value
      XCTAssertTrue(result.completed)
    }

    func testSystemAccountIsNotAcceptedAsAdministrator() throws {
      XCTAssertThrowsError(
        try requireRemovalAdministrator(
          MachineOwnerAuthorization(username: "nobody", password: Data("unused".utf8))))
    }

    // MARK: Helpers

    private func assertRefusal(
      _ disk: FakeRemovalDisk, _ message: String, file: StaticString = #filePath,
      line: UInt = #line
    ) {
      XCTAssertThrowsError(try OmarchyRemovalPlan(disks: disk), file: file, line: line) { error in
        XCTAssertEqual((error as? RemovalFailure)?.message, message, file: file, line: line)
      }
      XCTAssertTrue(disk.operations.isEmpty, file: file, line: line)
    }

    private func assertRefusalPrefix(
      _ disk: FakeRemovalDisk, _ prefix: String, file: StaticString = #filePath,
      line: UInt = #line
    ) {
      XCTAssertThrowsError(try OmarchyRemovalPlan(disks: disk), file: file, line: line) { error in
        let message = (error as? RemovalFailure)?.message ?? "\(error)"
        XCTAssertTrue(message.hasPrefix(prefix), message, file: file, line: line)
        XCTAssertTrue(message.hasSuffix("Nothing was changed."), message, file: file, line: line)
      }
    }

    private func server(root: URL, disk: FakeRemovalDisk) -> ClosedEngineHelperServer {
      ClosedEngineHelperServer(
        workingDirectory: root, executor: UnusedRemovalHandoffExecutor(),
        credentialValidator: RemovalCredentials(reject: false), removalDisks: disk,
        removalAdminValidator: { _ in })
    }
    @discardableResult
    private func writeRecord(_ root: URL, _ id: UUID, phase: String, retired: Bool?) throws -> URL {
      var object: [String: Any] = [
        "plan": ["members": [], "targetMacOSBytes": 1], "phase": phase,
      ]
      if let retired { object["executionJournalsRetired"] = retired }
      let record = root.appendingPathComponent("removal-\(id.uuidString).json")
      try JSONSerialization.data(withJSONObject: object).write(to: record)
      return record
    }
    private func makeInstallJournals(_ root: URL) throws -> URL {
      let journals = root.appendingPathComponent("execution-journals", isDirectory: true)
      try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: false)
      try Data(#"{"completion":"awaiting_recovery"}"#.utf8).write(
        to: journals.appendingPathComponent("abc.jsonl"))
      return journals
    }
    private func recordedRetirement(_ record: URL) throws -> Bool? {
      let object = try JSONSerialization.jsonObject(with: Data(contentsOf: record))
      return (object as? [String: Any])?["executionJournalsRetired"] as? Bool
    }
    /// What an install request runs into. Past the gates it fails on the
    /// test's stand-in package, never reaching the engine.
    private func submitError(_ service: ClosedEngineHelperServer) async -> (any Error)? {
      do {
        _ = try await service.submit(
          packageDirectory: .standardInput, authorization: authorization())
        return nil
      } catch {
        return error
      }
    }
    private func authorization() throws -> MachineOwnerAuthorization {
      try MachineOwnerAuthorization(username: "test-admin", password: Data("test-password".utf8))
    }
    private func temporaryDirectory() throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "removal-tests-\(UUID())")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      return root
    }
  }

  private struct RemovalCredentials: MachineOwnerCredentialValidating {
    let reject: Bool
    func validate(_ authorization: MachineOwnerAuthorization) throws {
      if reject { throw RemovalFailure(message: "password rejected") }
    }
  }
  private struct UnusedRemovalHandoffExecutor: ImportedEngineHandoffExecuting {
    func execute(
      _ package: ImportedEngineHandoffPackage, authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation
    ) async throws -> Data {
      XCTFail("Removal must not use the install engine")
      throw RemovalFailure(message: "unexpected install")
    }
  }

  private final class BlockingRemovalDisk: RemovalDiskOperating, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let disk = FakeRemovalDisk()
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func snapshot() throws -> RemovalSnapshot { try disk.snapshot() }
    func evidence(for installation: RemovalInstallation, disk: String) throws -> RemovalEvidence {
      try self.disk.evidence(for: installation, disk: disk)
    }
    func startup(_ snapshot: RemovalSnapshot) throws -> RemovalStartup {
      try disk.startup(snapshot)
    }
    func setMacOSStartup(
      _ snapshot: RemovalSnapshot, nextOnly: Bool, authorization: MachineOwnerAuthorization
    ) throws {
      try disk.setMacOSStartup(snapshot, nextOnly: nextOnly, authorization: authorization)
    }
    func growLimit(_ macOS: RemovalPartition, disk: String) throws -> UInt64 {
      try self.disk.growLimit(macOS, disk: disk)
    }
    func deleteContainer(_ stub: RemovalPartition, disk: String) throws {
      entered.signal()
      guard resume.wait(timeout: .now() + 10) == .success else {
        throw RemovalFailure(message: "test timeout")
      }
      try self.disk.deleteContainer(stub, disk: disk)
    }
    func erasePartition(_ partition: RemovalPartition, disk: String) throws {
      try self.disk.erasePartition(partition, disk: disk)
    }
    func growContainer(_ macOS: RemovalPartition, disk: String) throws {
      try self.disk.growContainer(macOS, disk: disk)
    }
  }

  private final class RecordingSelfUninstaller: HelperSelfUninstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let uninstallsAfterRemoval: Bool
    var calls: Int { lock.withLock { count } }
    init(uninstallsAfterRemoval: Bool = true) {
      self.uninstallsAfterRemoval = uninstallsAfterRemoval
    }
    func uninstallAfterRemoval() { lock.withLock { count += 1 } }
  }
#endif
