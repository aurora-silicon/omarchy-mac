#if os(macOS)
  import Foundation
  @testable import OmarchyAppleInstallerTrustCore

  /// Disk layouts for removal tests. Partition types, names, sizes and
  /// adjacency follow asahi-installer v0.9.2 (STUB_SIZE, ESP sizes, template
  /// order) and `diskutil info -plist` key shapes read on Apple silicon Macs.
  /// `converged` uses the real offsets, sizes and UUIDs of the M2 lab Mac's
  /// install (lsblk and its ESP's asahi/installer.log, 2026-09-27).
  enum RemovalFixtures {
    enum Row {
      case part(String, String, UInt64, name: String = "")
      case free(UInt64)
    }

    static let isc = "3613C051-7E6D-470E-9BCE-DEC4908D4FE0"
    static let mac = "D9F90C0A-CD08-4364-A983-D1924DC1FEA0"
    static let recovery = "DB1692D9-BBD5-4169-8075-2CC6083F3776"
    static let macContainer = "6B3F0C4E-1D2A-4C55-9E61-0F6A9B2C7D10"
    static let macGroup = "5E7A2C19-3B84-4D07-A6F1-2C9D8E4B6A01"

    /// boot-volume / alt-boot-volume as nvram prints them: the partition GUID
    /// has its first three fields byte-swapped.
    static func bootVolume(store: String, group: String) -> String {
      let b = UUID(uuidString: store)!.uuid
      let swapped = UUID(
        uuid: (
          b.3, b.2, b.1, b.0, b.5, b.4, b.7, b.6, b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15
        ))
      return "EF57347C-0000-AA11-AA11-00306543ECAC:\(swapped.uuidString):\(group)"
    }

    static func id(_ n: Int) -> String { String(format: "0A000000-0000-4000-8000-%012d", n) }

    struct Install {
      let name: String
      let stub: String
      let esp: String
      let linux: [String]
      let group: String
    }

    /// Lays partitions out from the ISC's usual offset, numbering disk0s1….
    static func snapshot(
      macOSSize: UInt64, _ rows: [Row], extraContainers: [RemovalContainer] = [],
      installs: [Install] = []
    ) -> RemovalSnapshot {
      var offset: UInt64 = 24_576
      var parts = [RemovalPartition]()
      let all: [Row] =
        [.part(isc, "Apple_APFS_ISC", 524_288_000), .part(mac, "Apple_APFS", macOSSize)] + rows
        + [.part(recovery, "Apple_APFS_Recovery", 5_368_664_064)]
      for row in all {
        switch row {
        case .free(let bytes): offset += bytes
        case .part(let uuid, let type, let size, let name):
          parts.append(
            RemovalPartition(
              identifier: "disk0s\(parts.count + 1)", uuid: uuid, type: type, offset: offset,
              size: size, name: name))
          offset += size
        }
      }
      let macOS = RemovalContainer(
        uuid: macContainer, storeUUID: mac,
        volumes: [
          RemovalVolume(
            uuid: id(901), name: "Macintosh HD", roles: ["System"], group: macGroup,
            identifier: "disk3s1"),
          RemovalVolume(
            uuid: macGroup, name: "Macintosh HD - Data", roles: ["Data"], group: macGroup,
            identifier: "disk3s5"),
          RemovalVolume(uuid: id(902), name: "Preboot", roles: ["Preboot"], identifier: "disk3s2"),
          RemovalVolume(
            uuid: id(903), name: "Recovery", roles: ["Recovery"], identifier: "disk3s3"),
          RemovalVolume(uuid: id(904), name: "VM", roles: ["VM"], identifier: "disk3s6"),
        ].sorted { $0.uuid < $1.uuid })
      let stubs = installs.enumerated().map { index, install in
        stubContainer(
          install.stub, name: install.name, group: install.group, disk: 4 + index,
          uuid: id(800 + index))
      }
      return RemovalSnapshot(
        disk: "disk0", devicePath: "IODeviceTree:/arm-io/ans", diskSize: offset + 20_480,
        macOSStoreUUID: mac, macOSContainerUUID: macContainer, partitions: parts,
        containers: ([macOS] + stubs + extraContainers).sorted { $0.uuid < $1.uuid })
    }

    static func stubContainer(
      _ store: String, name: String, group: String, disk: Int, uuid: String
    ) -> RemovalContainer {
      RemovalContainer(
        uuid: uuid, storeUUID: store,
        volumes: [
          RemovalVolume(
            uuid: group, name: "\(name) - Data", roles: ["Data"], group: group,
            identifier: "disk\(disk)s1"),
          RemovalVolume(
            uuid: id(700 + disk), name: name, roles: ["System"], group: group,
            identifier: "disk\(disk)s2"),
          RemovalVolume(
            uuid: id(710 + disk), name: "Preboot", roles: ["Preboot"],
            identifier: "disk\(disk)s3"),
          RemovalVolume(
            uuid: id(720 + disk), name: "Recovery", roles: ["Recovery"],
            identifier: "disk\(disk)s4"),
        ].sorted { $0.uuid < $1.uuid })
    }

    // MARK: Installations

    static let convergedInstall = Install(
      name: "Omarchy", stub: "A0913035-21F1-4CC5-B940-A26FD42BFA5C",
      esp: "BB18E021-9D1B-499C-8F25-849B7F5FCDCC",
      linux: ["E94DF227-99CE-438F-BE4B-9B7687487BDC", "2CE86A5F-AF65-404E-A04C-B51092F45D8F"],
      group: "14CA2D4A-5B90-4225-B462-48C7733D787C")

    /// This app's layout, from the M2 lab Mac: contiguous, no free space.
    static func converged() -> RemovalSnapshot {
      snapshot(
        macOSSize: 674_663_403_520,
        [
          .part(convergedInstall.stub, "Apple_APFS", 2_499_805_184),
          .part(convergedInstall.esp, "EFI", 524_288_000, name: "EFI - OMARC"),
          .part(convergedInstall.linux[0], "Linux Filesystem", 2_147_483_648),
          .part(convergedInstall.linux[1], "Linux Filesystem", 314_827_603_968),
        ], installs: [convergedInstall])
    }

    /// The MacBook Neo layout: macOS 26 firmware needs a 6 GB stub.
    static func neoMacos26() -> RemovalSnapshot {
      snapshot(
        macOSSize: 194_332_676_096,
        [
          .part(convergedInstall.stub, "Apple_APFS", 5_999_951_872),
          .part(convergedInstall.esp, "EFI", 524_288_000, name: "EFI - OMARC"),
          .part(convergedInstall.linux[0], "Linux Filesystem", 2_147_483_648),
          .part(convergedInstall.linux[1], "Linux Filesystem", 256_798_965_760),
        ], installs: [convergedInstall])
    }

    static let alarmInstall = Install(
      name: "Asahi Alarm Minimal", stub: id(3), esp: id(4), linux: [id(5)], group: id(600))

    /// omarchy-mac 3.x: asahi-alarm installer, "Asahi Alarm Minimal", one root
    /// partition. 32.8 GB in all, directly after macOS on a 500 GB Mac.
    static func alarm() -> RemovalSnapshot {
      snapshot(
        macOSSize: 461_584_287_744,
        [
          .part(alarmInstall.stub, "Apple_APFS", 2_499_805_184),
          .part(alarmInstall.esp, "EFI", 524_288_000, name: "EFI - ASAHI"),
          .part(alarmInstall.linux[0], "Linux Filesystem", 29_776_412_672),
        ], installs: [alarmInstall])
    }

    static let fedoraInstall = Install(
      name: "Fedora Linux with KDE Plasma", stub: id(13), esp: id(14), linux: [id(15), id(16)],
      group: id(610))

    /// Fedora Asahi Remix: ESP, 1 GiB /boot, root, and 10 GB the user left free.
    static func fedora() -> RemovalSnapshot {
      snapshot(
        macOSSize: 400_000_000_000,
        [
          .part(fedoraInstall.stub, "Apple_APFS", 2_499_805_184),
          .part(fedoraInstall.esp, "EFI", 524_288_000, name: "EFI - FEDOR"),
          .part(fedoraInstall.linux[0], "Linux Filesystem", 1_073_741_824),
          .part(fedoraInstall.linux[1], "Linux Filesystem", 60_000_000_000),
          .free(10_000_000_000),
        ], installs: [fedoraInstall])
    }

    static let uefiInstall = Install(
      name: "UEFI boot", stub: id(23), esp: id(24), linux: [], group: id(620))

    /// "UEFI environment only": startup container and ESP, nothing else.
    static func uefiOnly() -> RemovalSnapshot {
      snapshot(
        macOSSize: 400_000_000_000,
        [
          .part(uefiInstall.stub, "Apple_APFS", 2_499_805_184),
          .part(uefiInstall.esp, "EFI", 500_170_752, name: "EFI - UEFI"),
          .free(20_000_000_000),
        ], installs: [uefiInstall])
    }

    /// The reporter's likely state: partitions deleted by hand, 32.8 GB not yet returned.
    static func freeSpaceOnly() -> RemovalSnapshot {
      snapshot(macOSSize: 461_584_287_744, [.free(32_800_505_856)])
    }

    // MARK: Refusals

    static func foreignAPFS() -> RemovalSnapshot {
      snapshot(
        macOSSize: 400_000_000_000, [.part(id(33), "Apple_APFS", 50_000_000_000)],
        extraContainers: [
          RemovalContainer(
            uuid: id(830), storeUUID: id(33),
            volumes: [
              RemovalVolume(uuid: id(831), name: "Shared", roles: [], identifier: "disk6s1")
            ])
        ])
    }

    static func windows() -> RemovalSnapshot {
      snapshot(
        macOSSize: 400_000_000_000,
        [.part(id(43), "Microsoft Basic Data", 60_000_000_000, name: "BOOTCAMP")])
    }

    static func secondMacOS() -> RemovalSnapshot {
      let group = id(850)
      return snapshot(
        macOSSize: 400_000_000_000, [.part(id(53), "Apple_APFS", 80_000_000_000)],
        extraContainers: [
          RemovalContainer(
            uuid: id(851), storeUUID: id(53),
            volumes: [
              RemovalVolume(
                uuid: id(852), name: "Macintosh HD 2", roles: ["System"], group: group,
                identifier: "disk7s1"),
              RemovalVolume(
                uuid: group, name: "Macintosh HD 2 - Data", roles: ["Data"], group: group,
                identifier: "disk7s5"),
              RemovalVolume(
                uuid: id(853), name: "Preboot", roles: ["Preboot"], identifier: "disk7s2"),
              RemovalVolume(
                uuid: id(854), name: "Recovery", roles: ["Recovery"], identifier: "disk7s3"),
              RemovalVolume(uuid: id(855), name: "VM", roles: ["VM"], identifier: "disk7s6"),
            ])
        ])
    }

    /// A leftover Linux partition right after macOS, with the free space behind it.
    static func nonContiguousFree() -> RemovalSnapshot {
      snapshot(
        macOSSize: 400_000_000_000,
        [.part(id(63), "Linux Filesystem", 10_000_000_000), .free(32_800_505_856)])
    }

    // MARK: Files on an installation

    /// What asahi-installer leaves on the ESP and in the startup container.
    static func files(for install: Install, in snapshot: RemovalSnapshot) -> RemovalInstallFiles {
      let members = [install.stub, install.esp] + install.linux
      var log = [
        "09-27 12:59 root         INFO     Version: v0.9.2",
        "09-27 12:59 root         INFO     DiskUtil.addPartition(disk0s2, apfs, \(install.name), 2499805184)",
      ]
      for uuid in members {
        let part = snapshot.partitions.first { $0.uuid == uuid }!
        log.append(
          "09-27 12:59 root         INFO     New partition: Partition(name='\(part.identifier)', offset=\(part.offset), size=\(part.size), free=False, type='\(part.type)', uuid='\(uuid)', desc=None, label=None, info={'Content': '\(part.type)', 'DiskUUID': '\(uuid)'})"
        )
      }
      log.append("09-27 13:00 root         INFO     m1n1 vars:")
      let espLower = install.esp.lowercased()
      var bootObject = Data("m1n1 stage 1 ##m1n1_ver##v1.5.2\0 code STACKBOT".utf8)
      bootObject.append(
        Data(
          "chosen.asahi,efi-system-partition=\(espLower)\nchainload=\(espLower);m1n1/boot.bin\n"
            .utf8))
      bootObject.append(Data([0, 0, 0, 0]))
      let stubInfo =
        #"{"vgid": "\#(install.group)", "system_version": {"ProductUserVisibleVersion": "13.5 (stub)"}, "admin_users": {"tester": {"uid": "x", "real_name": "Test Owner"}}}"#
      return RemovalInstallFiles(
        espBootObject: Data("m1n1 stage 2 STACKBOT\0 u-boot".utf8),
        stubInfo: Data(stubInfo.utf8), installerLog: Data(log.joined(separator: "\n").utf8),
        stubHasLibrary: false, stubBootObject: bootObject)
    }
  }

  /// These commands mutate only an in-memory partition map, exercising the real executor.
  final class FakeRemovalDisk: RemovalDiskOperating, @unchecked Sendable {
    var state: RemovalSnapshot
    var files: RemovalInstallFiles?
    var startupState = RemovalStartup.macOS
    /// What each `setMacOSStartup` call leaves, in order; a thrown error
    /// is what bless reported.
    var startupAfterSet = [Result<RemovalStartup, RemovalStartupRefusal>]()
    /// `nextOnly` of each call, and whether a partition was already gone then.
    var startupWrites = [(nextOnly: Bool, afterDeletion: Bool)]()
    var startupPasswords = [Data]()
    var operations = [String]()
    var evidenceReads = 0
    var limitOverride: UInt64?
    var afterPlanning: ((FakeRemovalDisk) -> Void)?
    let failAt: Int?
    let skipGrowth: Bool

    init(
      _ state: RemovalSnapshot = RemovalFixtures.converged(),
      install: RemovalFixtures.Install? = RemovalFixtures.convergedInstall, failAt: Int? = nil,
      skipGrowth: Bool = false
    ) {
      self.state = state
      files = install.map { RemovalFixtures.files(for: $0, in: state) }
      self.failAt = failAt
      self.skipGrowth = skipGrowth
    }

    func snapshot() throws -> RemovalSnapshot { state }
    func evidence(for installation: RemovalInstallation, disk: String) throws -> RemovalEvidence {
      evidenceReads += 1
      if evidenceReads == 2 { afterPlanning?(self) }
      guard let files else {
        throw RemovalFailure(message: "disk0s4 couldn’t be read without mounting it.")
      }
      return RemovalEvidence(files: files)
    }
    func startup(_ snapshot: RemovalSnapshot) throws -> RemovalStartup { startupState }
    func setMacOSStartup(
      _ snapshot: RemovalSnapshot, nextOnly: Bool, authorization: MachineOwnerAuthorization
    ) throws {
      startupWrites.append((nextOnly, !operations.isEmpty))
      startupPasswords.append(authorization.password)
      guard !startupAfterSet.isEmpty else { throw RemovalStartupRefusal(reason: "unexpected") }
      startupState = try startupAfterSet.removeFirst().get()
    }
    func growLimit(_ macOS: RemovalPartition, disk: String) throws -> UInt64 {
      if let limitOverride { return limitOverride }
      let next = state.partitions.filter { $0.offset > macOS.offset }.map(\.offset).min()!
      return next - macOS.offset
    }
    func deleteContainer(_ stub: RemovalPartition, disk: String) throws {
      try record("container:\(stub.uuid)")
      state.partitions.removeAll { $0.uuid == stub.uuid }
      state.containers.removeAll { $0.storeUUID == stub.uuid }
    }
    func erasePartition(_ partition: RemovalPartition, disk: String) throws {
      try record("erase:\(partition.uuid)")
      state.partitions.removeAll { $0.uuid == partition.uuid }
    }
    func growContainer(_ macOS: RemovalPartition, disk: String) throws {
      try record("grow:\(macOS.uuid)")
      if !skipGrowth, let index = state.partitions.firstIndex(where: { $0.uuid == macOS.uuid }) {
        let next = state.partitions.filter { $0.offset > macOS.offset }.map(\.offset).min()!
        state.partitions[index].size = next - macOS.offset
      }
    }
    private func record(_ operation: String) throws {
      operations.append(operation)
      if operations.count == failAt { throw RemovalFailure(message: "injected command failure") }
    }
  }
#endif
