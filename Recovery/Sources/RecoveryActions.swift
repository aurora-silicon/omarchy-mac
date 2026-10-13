import CryptoKit
import Darwin
import Foundation
import RecoveryAuthorization

struct RecoveryFailure: Error, LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

enum RecoveryActions {
  // The engine writes this only after the new System volume and ESP exist.
  // Keep loading independent of diskutil so Recovery can show the window first.
  static let configuration: Result<InstallConfiguration, Error> = Result {
    guard let resources = Bundle.main.resourceURL else { throw InstallConfigurationError.invalid }
    return try InstallConfiguration.decode(
      Data(contentsOf: resources.appendingPathComponent("install-config.json")))
  }
  static var volume: URL {
    #if OMARCHY_STEP2_PREVIEW
      return URL(fileURLWithPath: "/Volumes/Omarchy")
    #else
      // The launch contract puts the app directly in the target System volume.
      // Resolve its actual mount point, not a name that Recovery might suffix.
      return Bundle.main.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
    #endif
  }
  static var systemUUID: String { (try? configuration.get().systemUUID) ?? "" }
  static var groupUUID: String { (try? configuration.get().groupUUID) ?? "" }
  static var prebootUUID: String { (try? configuration.get().prebootUUID) ?? "" }
  static var espUUID: String { (try? configuration.get().espUUID) ?? "" }
  static var volumeName: String { (try? configuration.get().volumeName) ?? "Omarchy" }
  static var supportsMachO: Bool {
    #if OMARCHY_STEP2_PREVIEW
      return true
    #else
      return false
    #endif
  }
  static var inRecovery: Bool {
    #if OMARCHY_STEP2_RECOVERY
      return FileManager.default.fileExists(atPath: "/System/Installation/CDIS")
    #else
      return false
    #endif
  }
  static var isPreview: Bool {
    #if OMARCHY_STEP2_PREVIEW
      return CommandLine.arguments.contains("--preview")
        || CommandLine.arguments.contains("--recovery-preview")
    #else
      return false
    #endif
  }
  static func requireEnrollmentEnvironment() throws {
    // Check cheap prerequisites before querying a target policy.
    if !inRecovery { throw EnrollmentGateIssue.notRecovery }
    if geteuid() != 0 { throw EnrollmentGateIssue.rootRequired }
    try verifyVolume()
    let report: Data
    do { report = try run("/usr/bin/bputil", ["-d", "-v", groupUUID]) } catch {
      throw EnrollmentGateIssue.cannotVerify
    }
    if let issue = EnrollmentGate.issue(
      isRecovery: true, isRoot: true,
      policy: String(decoding: report, as: UTF8.self))
    {
      InstallerLog.shared.append("Recovery environment rejected: \(issue.title). \(issue.message)")
      throw issue
    }
  }
  static var resources: URL { Bundle.main.resourceURL! }
  static var state: URL { volume.appendingPathComponent("Aurora/Recovery/State") }
  static var receipt: URL { state.appendingPathComponent("installation.json") }
  static var recovering: Bool { FileManager.default.fileExists(atPath: receipt.path) }

  static func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw RecoveryFailure(message: message) }
  }
  static func hash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  @discardableResult static func run(_ path: String, _ args: [String]) throws -> Data {
    let logged = path != "/usr/sbin/nvram"
    let log = logged ? CommandLog("$ " + ([path] + args).joined(separator: " ")) : nil
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch {
      log?.output("Could not launch: " + error.localizedDescription)
      throw error
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    log?.output(
      String(decoding: data, as: UTF8.self) + "\nExit status: \(process.terminationStatus)")
    try check(
      process.terminationStatus == 0,
      "\(URL(fileURLWithPath: path).lastPathComponent) failed (\(process.terminationStatus)).")
    return data
  }
  static func disk(_ path: String) throws -> [String: Any] {
    let data = try run("/usr/sbin/diskutil", ["info", "-plist", path])
    guard
      let info = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else {
      throw RecoveryFailure(message: "Cannot identify the selected volume.")
    }
    return info
  }
  static func verifyVolume() throws {
    _ = try configuration.get()
    let info = try disk(volume.path)
    try check(
      (info["VolumeUUID"] as? String)?.uppercased() == systemUUID
        && (info["APFSVolumeGroupID"] as? String)?.uppercased() == groupUUID
        && (info["MountPoint"] as? String) == volume.path,
      "The selected volume does not match this installation.")
  }
  static func resolveOwner() throws -> RecoveryOwner {
    try verifyVolume()
    let selected = try RecoveryAccountInstaller.selectedOwner(system: volume)
    let userData = try run("/usr/sbin/diskutil", ["apfs", "listUsers", systemUUID, "-plist"])
    guard
      let cryptoUsers = try PropertyListSerialization.propertyList(from: userData, format: nil)
        as? [String: Any]
    else {
      throw RecoveryOwnerError.noOwner
    }
    var pendingAccount: RecoveryOwner?
    if let selected {
      guard let uuid = UUID(uuidString: selected.generatedUID) else {
        throw RecoveryOwnerError.noOwner
      }
      let account = RecoveryOwner(username: selected.username, uuid: uuid)
      if RecoveryOwnerResolver.isOwner(account, users: cryptoUsers) { return account }
      guard ["prepared", "awaiting-ownership"].contains(selected.phase) else {
        throw RecoveryOwnerError.noOwner
      }
      pendingAccount = account
    }
    var preboot = try disk(prebootUUID)
    if (preboot["MountPoint"] as? String)?.isEmpty != false {
      try run("/usr/sbin/diskutil", ["mount", "readOnly", prebootUUID])
      preboot = try disk(prebootUUID)
    }
    guard (preboot["VolumeUUID"] as? String)?.uppercased() == prebootUUID,
      let mount = preboot["MountPoint"] as? String, mount.hasPrefix("/")
    else {
      throw RecoveryOwnerError.noOwner
    }
    let metadata = URL(fileURLWithPath: mount).appendingPathComponent(
      groupUUID + "/var/db/AdminUserRecoveryInfo.plist")
    // Read only identity fields; never log the recovery metadata contents.
    guard
      let admins = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: metadata), format: nil) as? [String: Any]
    else {
      throw RecoveryOwnerError.noOwner
    }
    let bootstrap = try configuration.get().bootstrap
    let owner = try RecoveryOwnerResolver.resolve(
      admins: admins, targetUsers: cryptoUsers, bootstrap: bootstrap,
      pendingAccount: pendingAccount,
      source: {
        guard let bootstrap else { throw RecoveryOwnerError.noOwner }
        let bytes = try run("/usr/sbin/diskutil", ["apfs", "list", "-plist"])
        guard
          let tree = try PropertyListSerialization.propertyList(from: bytes, format: nil)
            as? [String: Any]
        else { throw RecoveryOwnerError.noOwner }
        var candidates = [[String: Any]]()
        for container in tree["Containers"] as? [[String: Any]] ?? [] {
          for volume in container["Volumes"] as? [[String: Any]] ?? [] {
            let roles = volume["Roles"] as? [String] ?? []
            guard roles.contains("System"), let id = volume["APFSVolumeUUID"] as? String else {
              continue
            }
            var info = try disk(id)
            guard (info["VolumeUUID"] as? String)?.uppercased() == id.uppercased() else {
              throw RecoveryOwnerError.noOwner
            }
            info["Roles"] = roles
            candidates.append(info)
          }
        }
        let info = try RecoveryOwnerResolver.sourceSystem(
          group: bootstrap.sourceGroupUUID, candidates: candidates)
        guard let id = info["VolumeUUID"] as? String else { throw RecoveryOwnerError.noOwner }
        var snapshots = Set<String>()
        if id.uppercased() != bootstrap.sourceSystemUUID {
          if (info["MountPoint"] as? String)?.isEmpty != false {
            try run("/usr/sbin/diskutil", ["mount", "readOnly", id])
          }
          let bytes = try run("/usr/sbin/diskutil", ["apfs", "listSnapshots", id, "-plist"])
          guard
            let listing = try PropertyListSerialization.propertyList(from: bytes, format: nil)
              as? [String: Any]
          else { throw RecoveryOwnerError.noOwner }
          snapshots = RecoveryOwnerResolver.snapshotUUIDs(listing)
          guard snapshots.contains(bootstrap.sourceSystemUUID) else {
            throw RecoveryOwnerError.noOwner
          }
        }
        let data = try run(
          "/usr/sbin/diskutil", ["apfs", "listUsers", id, "-plist"])
        guard
          let users = try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
        else { throw RecoveryOwnerError.noOwner }
        return (info, users, snapshots)
      })
    InstallerLog.shared.append("Authorizing owner: \(owner.username) (\(owner.uuid.uuidString))")
    return owner
  }
  static func recoveryOnly() throws {
    try check(inRecovery && geteuid() == 0, "Open Omarchy Installer in its paired Recovery.")
    try verifyVolume()
  }
  static func esp() throws -> URL {
    var info = try disk(espUUID)
    try check(
      (info["DiskUUID"] as? String)?.uppercased() == espUUID
        && (info["Content"] as? String) == "EFI",
      "The startup partition does not match this installation.")
    if (info["MountPoint"] as? String)?.isEmpty != false {
      try run("/usr/sbin/diskutil", ["mount", espUUID])
      info = try disk(espUUID)
    }
    guard let path = info["MountPoint"] as? String, path.hasPrefix("/"), !path.isEmpty else {
      throw RecoveryFailure(message: "Cannot mount the startup partition.")
    }
    let mounted = try disk(path)
    try check(
      (mounted["DiskUUID"] as? String)?.uppercased() == espUUID,
      "The mounted startup partition does not match this installation.")
    return URL(fileURLWithPath: path)
  }
  static func relative(_ path: String) -> Bool {
    !path.isEmpty && !path.contains("\0")
      && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
      }
  }
  static func manifest() throws -> [String: Any] {
    let path = resources.appendingPathComponent("AuraPayloads/manifest.json")
    guard let m = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any],
      m["schema"] as? Int == 2
    else { throw RecoveryFailure(message: "The recovery payload manifest is invalid.") }
    return m
  }
  static func asset(_ name: String, manifest: [String: Any]) throws -> Data {
    try RecoveryBaseline.asset(
      name, manifest: manifest, root: resources.appendingPathComponent("AuraPayloads"))
  }
  static func atomic(_ bytes: Data, to target: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: target, options: .atomic)
    let fd = open(target.path, O_RDONLY | O_NOFOLLOW)
    try check(fd >= 0, "Cannot verify the saved file.")
    defer { close(fd) }
    try check(fsync(fd) == 0, "Could not flush the saved file.")
    try check(try Data(contentsOf: target) == bytes, "Saved file verification failed.")
    sync()
  }
  static func saveJSON(_ object: [String: Any], to path: URL) throws {
    try atomic(
      JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
      to: path)
  }
  static func authorized(
    _ executable: String, _ arguments: [String], owner: RecoveryOwner, password: String
  ) throws {
    let log = CommandLog("$ " + ([executable] + arguments).joined(separator: " "))
    let context = Unmanaged.passUnretained(log).toOpaque()
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    defer { for p in argv { if let p { free(p) } } }
    let result = argv.withUnsafeBufferPointer { pointers in
      executable.withCString { command in
        owner.username.withCString { user in
          password.withCString { secret in
            aurora_authorized_command_logged(
              command, pointers.baseAddress, user, secret,
              { text, context in
                guard let text, let context else { return }
                Unmanaged<CommandLog>.fromOpaque(context).takeUnretainedValue().output(
                  String(cString: text))
              }, context)
          }
        }
      }
    }
    let name = URL(fileURLWithPath: executable).lastPathComponent
    let reason =
      result < 0 ? String(cString: aurora_authorization_failure(result)) : "exit status \(result)"
    InstallerLog.shared.append("\(name): \(result == 0 ? "completed" : reason)")
    try check(result == 0, "\(name) failed: \(reason). Open Show details for the command output.")
  }
  static func install(
    selection: BootSelection, owner: RecoveryOwner, password: String,
    progress: @escaping (Double, String) -> Void
  ) throws {
    // Repeat the check here so bypassing the GUI cannot reach any write.
    try requireEnrollmentEnvironment()
    InstallerLog.shared.append(
      "Recovery environment verified. Checking the installation’s recovery account.")
    if let selected = try RecoveryAccountInstaller.selectedOwner(system: volume) {
      if owner.uuid.uuidString == selected.generatedUID {
        InstallerLog.shared.append(
          "Verifying the recovery account and completing its ownership metadata.")
        let final = try RecoveryAccountInstaller.finalize(
          selected.target, password: Data(password.utf8))
        try RecoveryAccountInstaller.requireOwnership(final)
        InstallerLog.shared.append("Recovery account ownership verified.")
      } else {
        try check(
          ["prepared", "awaiting-ownership"].contains(selected.phase),
          "The recovery account is not ready for initial enrollment.")
        InstallerLog.shared.append(
          "Initial enrollment uses the recorded macOS owner. Authorize the new recovery account in Startup Disk after setup."
        )
      }
    }
    let config = try configuration.get()
    try check(
      selection.mode == .raw && !selection.nestedVirtualization,
      "This installation includes raw boot mode only.")
    try RecoveryOwnerResolver.verify(owner, current: resolveOwner())
    progress(0.05, "Verifying the installation files")
    let m = try manifest()
    let stage1 = try asset(selection.mode.stage1Path, manifest: m)
    let stage2 = try asset(selection.mode.stage2Path, manifest: m)
    // A successful setup must retain a usable per-device repair baseline.
    _ = try RecoveryBaseline.firmware(
      manifest: m, root: resources.appendingPathComponent("AuraPayloads"))
    let modes = m["modes"] as? [String: [String: Any]]
    guard let entry = modes?[selection.mode.rawValue],
      let destination = entry["espPath"] as? String, destination == config.stage2Path
    else {
      throw RecoveryFailure(
        message: "This boot mode’s complete startup bundle has not been staged yet.")
    }
    progress(0.15, "Checking the recovery environment")
    try run("/sbin/mount", ["-u", "-w", volume.path])
    let operation = state.appendingPathComponent("operation-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: operation, withIntermediateDirectories: true)
    InstallerLog.shared.persist(to: operation.appendingPathComponent("installer.log"))
    let stage1Path = operation.appendingPathComponent("stage1")
    try atomic(stage1, to: stage1Path)
    let target = try esp().appendingPathComponent(destination)
    let old = try? Data(contentsOf: target)
    if let old { try atomic(old, to: operation.appendingPathComponent("stage2.before")) }
    try saveJSON(
      ["status": "prepared", "mode": selection.mode.rawValue, "target": target.path],
      to: operation.appendingPathComponent("journal.json"))
    progress(0.3, "Authorizing the boot environment")
    try authorized("/usr/bin/bputil", ["-nca", "-v", groupUUID], owner: owner, password: password)
    let isc = URL(fileURLWithPath: "/System/Volumes/iSCPreboot/" + groupUUID)
    if FileManager.default.fileExists(atPath: isc.appendingPathComponent("boot").path) {
      try run("/usr/sbin/diskutil", ["mount", prebootUUID])
      let preboot = try disk(prebootUUID)
      guard let mount = preboot["MountPoint"] as? String else {
        throw RecoveryFailure(message: "Cannot mount Preboot.")
      }
      let destination = isc.appendingPathComponent("var")
      if FileManager.default.fileExists(atPath: destination.path) {
        try run(
          "/usr/bin/ditto",
          [destination.path, operation.appendingPathComponent("isc-var.before").path])
      }
      try run("/usr/bin/ditto", [mount + "/" + groupUUID + "/var", destination.path])
    }
    progress(0.55, "Installing the startup software")
    try atomic(stage2, to: target)
    do {
      try authorized(
        "/usr/bin/kmutil",
        selection.mode.enrollmentArguments(stage1: stage1Path.path, volume: volume.path),
        owner: owner, password: password)
    } catch {
      if let old { try atomic(old, to: target) }
      throw error
    }
    progress(0.85, "Finishing installation")
    // Keep the GUI, CLI, payloads and rollback record after disabling autolaunch.
    let marker = volume.appendingPathComponent(".IAPhysicalMedia")
    if FileManager.default.fileExists(atPath: marker.path) {
      try atomic(
        Data(contentsOf: marker),
        to: volume.appendingPathComponent("IAPhysicalMedia-disabled.plist"))
      try FileManager.default.removeItem(at: marker)
    }
    let core = volume.appendingPathComponent("System/Library/CoreServices")
    let disabled = core.appendingPathComponent("SystemVersion-disabled.plist")
    if FileManager.default.fileExists(atPath: disabled.path) {
      try atomic(Data(contentsOf: disabled), to: core.appendingPathComponent("SystemVersion.plist"))
      try FileManager.default.removeItem(at: disabled)
    }
    try saveJSON(
      [
        "schema": 1, "mode": selection.mode.rawValue, "stage2Path": destination,
        "stage1SHA256": hash(stage1), "stage2SHA256": hash(stage2),
        "nestedVirtualization": selection.nestedVirtualization, "status": "installed",
        "recoveryAccountRequired": true,
        "operation": operation.path,
      ], to: receipt)
    progress(1, "Installation complete")
  }
  static func targetIsDefaultBoot() throws -> Bool {
    let bytes = try run("/usr/sbin/bless", ["--getBoot", "--plist"])
    guard
      let info = try PropertyListSerialization.propertyList(from: bytes, format: nil)
        as? [String: Any],
      let boot = info["Boot Volume"] as? String
    else {
      throw RecoveryFailure(
        message: "Couldn’t read the default startup volume. The Mac has not been shut down.")
    }
    return (try disk(boot)["VolumeUUID"] as? String)?.uppercased() == systemUUID
  }

  // Returns false when owner authorization is needed. This repair deliberately
  // does not require paired 1TR: its purpose is to get the user into that mode.
  static func repairRecoveryBoot(password: String? = nil, owner: RecoveryOwner? = nil) throws
    -> Bool
  {
    try recoveryOnly()
    if try !targetIsDefaultBoot(), password == nil { return false }
    do {
      try RecoveryBootRepair.perform(
        isTargetDefault: targetIsDefaultBoot,
        selectTarget: {
          guard let password, let owner else {
            throw RecoveryFailure(
              message:
                "The startup selection changed. Try again to authorize Omarchy as the startup disk."
            )
          }
          try RecoveryOwnerResolver.verify(owner, current: resolveOwner())
          try authorized(
            "/usr/sbin/bless", ["--mount", volume.path, "--setBoot", "--user", owner.username],
            owner: owner, password: password)
        },
        shutDown: {
          try run("/sbin/shutdown", ["-h", "now"])
        })
    } catch RecoveryBootRepair.Failure.selectionNotVerified {
      throw RecoveryFailure(
        message: "Omarchy was not confirmed as the startup disk. The Mac has not been shut down.")
    }
    return true
  }

  static func prepareStartupDiskHandoff() throws -> URL {
    try recoveryOnly()
    _ = try installed()
    try RecoveryVersionMetadata.showForStartupDisk(system: volume)
    let application = URL(fileURLWithPath: "/System/Applications/Utilities/Startup Disk.app")
    try check(
      FileManager.default.fileExists(atPath: application.path),
      "Startup Disk is unavailable. Choose Apple menu → Startup Disk.")
    return application
  }

  static func accountTarget() throws -> RecoveryAccountTarget {
    try recoveryOnly()
    _ = try installed()
    let system = try disk(systemUUID)
    guard let containerID = system["APFSContainerReference"] as? String else {
      throw RecoveryFailure(message: "Cannot identify this installation’s APFS container.")
    }
    let bytes = try run("/usr/sbin/diskutil", ["apfs", "list", "-plist"])
    guard
      let tree = try PropertyListSerialization.propertyList(from: bytes, format: nil)
        as? [String: Any], let containers = tree["Containers"] as? [[String: Any]]
    else { throw RecoveryFailure(message: "Cannot inspect the installation volumes.") }
    let matches = containers.filter { $0["ContainerReference"] as? String == containerID }
    guard matches.count == 1 else {
      throw RecoveryFailure(message: "The installation’s APFS container is ambiguous.")
    }
    let volumes = matches[0]["Volumes"] as? [[String: Any]] ?? []
    for (id, role) in [(systemUUID, "System"), (prebootUUID, "Preboot")] {
      try check(
        volumes.filter {
          ($0["APFSVolumeUUID"] as? String)?.uppercased() == id
            && ($0["Roles"] as? [String] ?? []).contains(role)
        }.count == 1,
        "The installation’s \(role) volume does not match its configuration.")
    }
    var candidates = [String]()
    for volume in volumes {
      guard (volume["Roles"] as? [String] ?? []).contains("Data"),
        let id = volume["APFSVolumeUUID"] as? String
      else { continue }
      let info = try disk(id)
      if (info["APFSVolumeGroupID"] as? String)?.uppercased() == groupUUID,
        info["APFSContainerReference"] as? String == containerID
      {
        candidates.append(id.uppercased())
      }
    }
    guard candidates.count == 1 else {
      throw RecoveryFailure(message: "Cannot identify this installation’s Data volume.")
    }
    let target = RecoveryAccountTarget(
      volumeName: volumeName, systemUUID: systemUUID, dataUUID: candidates[0],
      groupUUID: groupUUID, prebootUUID: prebootUUID)
    try target.validate()
    return target
  }

  static func recoveryAccount() throws -> RecoveryAccountRecord? {
    try RecoveryAccountInstaller.inspect(accountTarget())
  }

  static func accountCreationRequired() throws -> Bool {
    try installed()["recoveryAccountRequired"] as? Bool == true
  }

  static func createRecoveryAccount(username: String, password: Data) throws {
    let target = try accountTarget()
    try RecoveryAccountInstaller.refreshMountedGroup(target)
    _ = try RecoveryAccountInstaller.prepare(target, username: username, password: password)
  }
}

extension RecoveryActions {
  static func installed() throws -> [String: Any] {
    guard
      let value = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt))
        as? [String: Any],
      value["status"] as? String == "installed"
    else {
      throw RecoveryFailure(message: "Complete Aurora installation first.")
    }
    return value
  }
  static func readBootArguments() throws -> String {
    let data = try run("/usr/sbin/nvram", ["-x", "-p"])
    guard
      let values = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else {
      throw RecoveryFailure(message: "Cannot read firmware boot arguments.")
    }
    if let string = values["boot-args"] as? String { return string }
    if let bytes = values["boot-args"] as? Data, let string = String(data: bytes, encoding: .utf8) {
      return string
    }
    try check(values["boot-args"] == nil, "Firmware boot arguments have an unexpected encoding.")
    return ""
  }
  static func bootArguments(_ current: String, flag: String, enabled: Bool) -> String {
    precondition(flag == "aura-debug" || flag == "aura-proxy")
    let regex = try! NSRegularExpression(
      pattern: "(?<!\\S)" + NSRegularExpression.escapedPattern(for: flag) + "(?!\\S)")
    let cleaned = regex.stringByReplacingMatches(
      in: current, range: NSRange(current.startIndex..., in: current), withTemplate: "")
    if enabled {
      return cleaned + (cleaned.isEmpty || cleaned.last!.isWhitespace ? "" : " ") + flag
    }
    return cleaned
  }
  static func cli(_ arguments: [String]) throws {
    try recoveryOnly()
    try run("/sbin/mount", ["-u", "-w", volume.path])
    switch arguments {
    case ["recover"]:
      let record = try installed()
      guard let name = record["mode"] as? String, let mode = AuraBootMode(rawValue: name),
        let path = record["stage2Path"] as? String,
        path == RecoveryBaseline.stage2Path, path == (try configuration.get()).stage2Path
      else {
        throw RecoveryFailure(message: "The installed boot mode is not recorded.")
      }
      let m = try manifest()
      try check(
        hash(try asset(mode.stage1Path, manifest: m)) == record["stage1SHA256"] as? String,
        "The recovery baseline does not match the enrolled stage 1.")
      let bytes = try asset(mode.stage2Path, manifest: m)
      var files = try RecoveryBaseline.firmware(
        manifest: m, root: resources.appendingPathComponent("AuraPayloads"))
      files[path] = bytes
      let destination = try esp()
      let backup = state.appendingPathComponent("recover-" + UUID().uuidString + ".before")
      try RecoveryBaseline.restore(files: files, root: destination, backup: backup) {
        try atomic($0, to: $1)
      }
      print("Stage 2 and device firmware restored.")
    case ["nv", "on"], ["nv", "off"]:
      let record = try installed()
      try check(
        record["mode"] as? String == "macho", "Nested virtualization requires Mach-O boot mode.")
      let m = try manifest()
      guard let modes = m["modes"] as? [String: [String: Any]],
        let path = modes["macho"]?["nvConfigPath"] as? String, relative(path)
      else {
        throw RecoveryFailure(
          message: "This native bundle does not provide an NV configuration path.")
      }
      let target = try esp().appendingPathComponent(path)
      let enabled = arguments[1] == "on"
      let previous = try Data(contentsOf: target)
      try check(
        previous == Data("x1n1.nv2=0\n".utf8) || previous == Data("x1n1.nv2=1\n".utf8),
        "Unexpected NV configuration; it was left unchanged.")
      try atomic(previous, to: state.appendingPathComponent("nv-" + UUID().uuidString + ".before"))
      try atomic(Data("x1n1.nv2=\(enabled ? 1 : 0)\n".utf8), to: target)
      print("Nested virtualization \(enabled ? "enabled" : "disabled") for the next boot.")
    case ["debug", "on"], ["debug", "off"], ["proxy", "on"], ["proxy", "off"]:
      let before = try readBootArguments()
      let after = bootArguments(before, flag: "aura-" + arguments[0], enabled: arguments[1] == "on")
      try atomic(
        Data(before.utf8),
        to: state.appendingPathComponent("boot-args-" + UUID().uuidString + ".before"))
      try run("/usr/sbin/nvram", ["boot-args=" + after])
      try check(try readBootArguments() == after, "Firmware boot arguments did not verify.")
      print("Aura \(arguments[0]) \(arguments[1]) for the next boot.")
    default:
      throw RecoveryFailure(
        message: "Usage: aura [recover | nv on/off | debug on/off | proxy on/off]")
    }
  }
  static func installCommand() throws {
    guard inRecovery else { return }
    try recoveryOnly()
    try run("/sbin/mount", ["-u", "-w", volume.path])
    let fm = FileManager.default
    guard let executable = Bundle.main.executableURL else {
      throw InstallConfigurationError.invalid
    }
    // Single-quote the runtime path; volume names may contain shell metacharacters.
    let command = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let script =
      "#!/bin/sh\nif [ \"$#\" -eq 0 ]; then\n  exec \(command)\nfi\nexec \(command) --aura-command \"$@\"\n"
    let persistent = volume.appendingPathComponent("aura")
    try atomic(Data(script.utf8), to: persistent)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: persistent.path)
    // Recovery's root can be read-only. Try its conventional local bin,
    // then install into its writable home and initialize new shell sessions.
    let local = URL(fileURLWithPath: "/usr/local/bin")
    do {
      try fm.createDirectory(at: local, withIntermediateDirectories: true)
      let link = local.appendingPathComponent("aura")
      if !fm.fileExists(atPath: link.path) {
        try fm.createSymbolicLink(at: link, withDestinationURL: persistent)
      }
      if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == persistent.path { return }
    } catch {}
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let bin = home.appendingPathComponent("bin")
    try fm.createDirectory(at: bin, withIntermediateDirectories: true)
    let link = bin.appendingPathComponent("aura")
    if !fm.fileExists(atPath: link.path) {
      try fm.createSymbolicLink(at: link, withDestinationURL: persistent)
    }
    try check(
      (try? fm.destinationOfSymbolicLink(atPath: link.path)) == persistent.path,
      "An existing aura command was left unchanged.")
    let line = "\n# Aurora Recovery command\nexport PATH=\"$HOME/bin:$PATH\"\n"
    for name in [".zprofile", ".zshrc", ".bash_profile", ".profile"] {
      let file = home.appendingPathComponent(name)
      let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
      if !old.contains("# Aurora Recovery command") {
        try atomic(Data((old + line).utf8), to: file)
      }
    }
  }
}
