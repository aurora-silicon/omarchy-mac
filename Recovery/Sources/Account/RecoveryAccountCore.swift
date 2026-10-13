import CryptoKit
import Darwin
import Foundation
import RecoveryAuthorization

public struct RecoveryAccountTarget: Codable, Equatable, Sendable {
  public let volumeName: String
  public let systemUUID: String
  public let dataUUID: String
  public let groupUUID: String
  public let prebootUUID: String

  public init(
    volumeName: String, systemUUID: String, dataUUID: String, groupUUID: String, prebootUUID: String
  ) {
    self.volumeName = volumeName
    self.systemUUID = systemUUID
    self.dataUUID = dataUUID
    self.groupUUID = groupUUID
    self.prebootUUID = prebootUUID
  }

  public func validate() throws {
    for value in [systemUUID, dataUUID, groupUUID, prebootUUID] {
      guard let id = UUID(uuidString: value), id.uuidString == value,
        value != "00000000-0000-0000-0000-000000000000"
      else { throw AccountSetupFailure("The recovery account target is invalid.") }
    }
    guard Set([systemUUID, dataUUID, prebootUUID]).count == 3,
      !volumeName.isEmpty, volumeName.count <= 80, !volumeName.contains("/")
    else { throw AccountSetupFailure("The recovery account target is invalid.") }
  }
}

public struct RecoveryAccountRecord: Codable, Equatable, Sendable {
  public var schema = 1
  public let target: RecoveryAccountTarget
  public let username: String
  public let generatedUID: String
  public var phase: String
  public var tokenReconciled: Bool = false

  public init(target: RecoveryAccountTarget, username: String, generatedUID: String, phase: String)
  {
    self.target = target
    self.username = username
    self.generatedUID = generatedUID
    self.phase = phase
  }

  public func validate() throws {
    try target.validate()
    guard schema == 1, RecoveryAccountInstaller.validName(username),
      UUID(uuidString: generatedUID)?.uuidString == generatedUID,
      ["creating", "prepared", "awaiting-ownership", "finalized"].contains(phase)
    else { throw AccountSetupFailure("The recovery account resume record is invalid.") }
  }
}

public struct AccountSetupFailure: Error, LocalizedError, Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

public struct AccountCommandResult: Sendable {
  public let status: Int32
  public let output: Data
}

public enum AccountNativeCommand {
  public static func run(
    _ executable: String, _ arguments: [String], input: Data = Data(), timeout: UInt32 = 60
  ) throws -> AccountCommandResult {
    guard input.count <= 8192 else {
      throw AccountSetupFailure("The supplied account input is too long.")
    }
    let strings = ([executable] + arguments).map { strdup($0) }
    defer { for string in strings { free(string) } }
    var pointers: [UnsafePointer<CChar>?] = strings.map { pointer in
      pointer.map { UnsafePointer<CChar>($0) }
    }
    pointers.append(nil)
    var output: UnsafeMutablePointer<UInt8>?
    var size = 0
    let status = pointers.withUnsafeBufferPointer { argv in
      input.withUnsafeBytes { bytes in
        omarchy_account_command(
          executable, argv.baseAddress, bytes.bindMemory(to: UInt8.self).baseAddress, input.count,
          &output, &size, timeout)
      }
    }
    defer { omarchy_account_free(output) }
    guard status >= 0, status != 126, status != 127 else {
      throw AccountSetupFailure(
        "A native account command could not finish. Your installation has been preserved.")
    }
    return AccountCommandResult(
      status: status, output: output.map { Data(bytes: $0, count: size) } ?? Data())
  }

  @discardableResult public static func checked(
    _ executable: String, _ arguments: [String], input: Data = Data(), timeout: UInt32 = 60
  ) throws -> Data {
    let result = try run(executable, arguments, input: input, timeout: timeout)
    guard result.status == 0 else {
      throw AccountSetupFailure(
        "\(URL(fileURLWithPath: executable).lastPathComponent) could not complete the account setup."
      )
    }
    return result.output
  }

  public static func disk(_ identifier: String) throws -> [String: Any] {
    let data = try checked("/usr/sbin/diskutil", ["info", "-plist", identifier])
    guard
      let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else {
      throw AccountSetupFailure("Couldn’t identify the recovery account volume.")
    }
    return value
  }
}

public enum RecoveryAccountInstaller {
  public static let stateRelativePath = "private/var/db/omarchy-recovery-account/state.json"
  public static let pointerRelativePath = "Aurora/Recovery/account-target.json"

  public static func validName(_ name: String) -> Bool {
    name.range(of: "\\A[a-z][a-z0-9_-]{0,30}\\z", options: .regularExpression) != nil
      && !["root", "daemon", "nobody"].contains(name)
  }

  public static func validatePassword(_ password: Data) throws {
    guard !password.isEmpty, password.count <= 4096, String(data: password, encoding: .utf8) != nil,
      !password.contains(0), !password.contains(10), !password.contains(13)
    else { throw AccountSetupFailure("Use a nonempty password without line breaks.") }
  }

  struct Context {
    let target: RecoveryAccountTarget
    let system: URL
    let data: URL
    let preboot: URL
    var database: URL { data.appendingPathComponent("private/var/db/dslocal/nodes/Default") }
    var state: URL { data.appendingPathComponent(stateRelativePath) }
    var metadata: URL { preboot.appendingPathComponent(target.groupUUID + "/var/db") }
  }

  static func context(_ target: RecoveryAccountTarget, writable: Bool) throws -> Context {
    try target.validate()
    guard geteuid() == 0 else {
      throw AccountSetupFailure("The installer helper must prepare the recovery account.")
    }
    let running = try AccountNativeCommand.disk("/")
    guard (running["APFSVolumeGroupID"] as? String)?.uppercased() != target.groupUUID else {
      throw AccountSetupFailure(
        "The running macOS installation cannot be used as the recovery stub.")
    }
    var infos = [[String: Any]]()
    var mounts = [URL]()
    for identifier in [target.systemUUID, target.dataUUID, target.prebootUUID] {
      var info = try AccountNativeCommand.disk(identifier)
      if (info["MountPoint"] as? String)?.isEmpty != false {
        _ = try AccountNativeCommand.checked("/usr/sbin/diskutil", ["mount", identifier])
        info = try AccountNativeCommand.disk(identifier)
      }
      guard (info["VolumeUUID"] as? String)?.uppercased() == identifier,
        let mount = info["MountPoint"] as? String, mount.hasPrefix("/Volumes/")
      else { throw AccountSetupFailure("The mounted recovery volume changed.") }
      infos.append(info)
      mounts.append(URL(fileURLWithPath: mount, isDirectory: true))
    }
    guard
      infos.prefix(2).allSatisfy({
        ($0["APFSVolumeGroupID"] as? String)?.uppercased() == target.groupUUID
      }),
      let container = infos[0]["APFSContainerReference"] as? String,
      infos.allSatisfy({ $0["APFSContainerReference"] as? String == container }),
      infos[1]["GlobalPermissionsEnabled"] as? Bool == true
    else {
      throw AccountSetupFailure("The recovery volumes do not belong to the same installation.")
    }
    if writable {
      for mount in mounts {
        _ = try AccountNativeCommand.checked("/sbin/mount", ["-u", "-w", mount.path])
      }
    }
    return Context(target: target, system: mounts[0], data: mounts[1], preboot: mounts[2])
  }

  public static func inspect(_ target: RecoveryAccountTarget) throws -> RecoveryAccountRecord? {
    let ctx = try context(target, writable: false)
    guard FileManager.default.fileExists(atPath: ctx.state.path) else { return nil }
    let result = try JSONDecoder().decode(
      RecoveryAccountRecord.self, from: protectedRead(ctx.state, limit: 65536))
    try result.validate()
    guard result.target == target else {
      throw AccountSetupFailure("The account belongs to another installation.")
    }
    return result
  }

  public static func pointer(system: URL) throws -> RecoveryAccountRecord? {
    let path = system.appendingPathComponent(pointerRelativePath)
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    let record = try JSONDecoder().decode(
      RecoveryAccountRecord.self, from: protectedRead(path, limit: 65536))
    try record.validate()
    return record
  }

  public static func selectedOwner(system: URL) throws -> RecoveryAccountRecord? {
    guard let pointer = try pointer(system: system) else { return nil }
    let actual = try AccountNativeCommand.disk(system.path)
    guard (actual["VolumeUUID"] as? String)?.uppercased() == pointer.target.systemUUID,
      let saved = try inspect(pointer.target), saved.target == pointer.target,
      saved.username == pointer.username, saved.generatedUID == pointer.generatedUID
    else {
      throw AccountSetupFailure("The recovery account record does not match this installation.")
    }
    return saved
  }

  public static func protectedRead(_ path: URL, limit: Int) throws -> Data {
    let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
      throw AccountSetupFailure("A protected account record could not be read.")
    }
    var status = stat()
    guard fstat(fd, &status) == 0, status.st_uid == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_mode & 0o022 == 0, status.st_size > 0, status.st_size <= limit
    else {
      close(fd)
      throw AccountSetupFailure("A protected account record is unsuitable.")
    }
    return try FileHandle(fileDescriptor: fd, closeOnDealloc: true).readToEnd() ?? Data()
  }

  static func save(_ record: RecoveryAccountRecord, _ ctx: Context) throws {
    try record.validate()
    let bytes = try JSONEncoder().encode(record)
    for url in [ctx.state, ctx.system.appendingPathComponent(pointerRelativePath)] {
      try directory(url.deletingLastPathComponent())
      try bytes.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      guard chown(url.path, 0, 0) == 0 else {
        throw AccountSetupFailure("Couldn’t protect the account record.")
      }
      let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard descriptor >= 0 else { throw AccountSetupFailure("Couldn’t save the account record.") }
      let synced = fsync(descriptor)
      close(descriptor)
      guard synced == 0 else {
        throw AccountSetupFailure("Couldn’t synchronize the account record.")
      }
      let parent = open(
        url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard parent >= 0 else { throw AccountSetupFailure("Couldn’t save the account directory.") }
      let directorySynced = fsync(parent)
      close(parent)
      guard directorySynced == 0 else {
        throw AccountSetupFailure("Couldn’t synchronize the account directory.")
      }
    }
  }

  static func directory(_ url: URL) throws {
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in url.pathComponents.dropFirst() {
      current.appendPathComponent(component, isDirectory: true)
      var status = stat()
      if lstat(current.path, &status) == 0 {
        guard status.st_mode & S_IFMT == S_IFDIR else {
          throw AccountSetupFailure("An account directory is indirect or unsuitable.")
        }
      } else {
        guard errno == ENOENT, mkdir(current.path, 0o700) == 0 else {
          throw AccountSetupFailure("Couldn’t create the account directory.")
        }
        guard chown(current.path, 0, 0) == 0 else {
          throw AccountSetupFailure("Couldn’t protect the account directory.")
        }
      }
    }
  }

  static func ds(_ ctx: Context, _ args: [String], input: Data = Data()) throws -> String {
    let result = try AccountNativeCommand.run(
      "/usr/bin/dscl", ["-f", ctx.database.path, "localonly"] + args, input: input, timeout: 30)
    let output = String(decoding: result.output, as: UTF8.self)
    guard result.status == 0, !output.contains("DS Error:"), !output.contains("failed."),
      !output.contains("Invalid Path")
    else {
      throw AccountSetupFailure(
        "The target account database could not complete \(args.first ?? "authentication").")
    }
    return output
  }

  static func authenticate(_ ctx: Context, _ username: String, _ password: Data) throws -> Bool {
    var input = Data("cd /Local/Target\nauthonly \(username)\n".utf8)
    input.append(password)
    input.append(Data("\nquit\n".utf8))
    let result = try AccountNativeCommand.run(
      "/usr/bin/dscl", ["-f", ctx.database.path, "localonly"], input: input, timeout: 30)
    let output = String(decoding: result.output, as: UTF8.self)
    guard output.contains("Password:"), output.contains("Goodbye") else {
      throw AccountSetupFailure("Native password verification did not complete.")
    }
    if output.contains("eDSAuthFailed"),
      output.contains("Authentication for node /Local/Target failed.")
    {
      return false
    }
    guard result.status == 0, !output.contains("DS Error:"), !output.contains("failed."),
      !output.contains("Unknown command")
    else {
      throw AccountSetupFailure("Native password verification could not complete.")
    }
    return true
  }

  static func user(_ ctx: Context, _ name: String) throws -> [String: Any] {
    let value = try PropertyListSerialization.propertyList(
      from: protectedRead(
        ctx.database.appendingPathComponent("users/\(name).plist"), limit: 4 << 20), format: nil)
    guard let record = value as? [String: Any] else {
      throw AccountSetupFailure("The native account record is invalid.")
    }
    return record
  }

  static func waitForUser(_ ctx: Context, _ record: RecoveryAccountRecord) throws {
    let deadline = Date().addingTimeInterval(10)
    repeat {
      if let current = try? user(ctx, record.username),
        current["generateduid"] as? [String] == [record.generatedUID],
        !(current["ShadowHashData"] as? [Data] ?? []).isEmpty,
        !(current["authentication_authority"] as? [String] ?? []).contains(
          ";DisabledTags;SecureToken")
      {
        return
      }
      Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    throw AccountSetupFailure(
      "The native account has not finished saving. Continue again to resume.")
  }

  static func users(_ target: RecoveryAccountTarget) throws -> [[String: Any]] {
    let bytes = try AccountNativeCommand.checked(
      "/usr/sbin/diskutil", ["apfs", "listUsers", "-plist", target.dataUUID])
    guard
      let object = try PropertyListSerialization.propertyList(from: bytes, format: nil)
        as? [String: Any], let users = object["Users"] as? [[String: Any]]
    else {
      throw AccountSetupFailure("Couldn’t inspect the target’s APFS users.")
    }
    return users
  }

  public static func prepare(_ target: RecoveryAccountTarget, username: String, password: Data)
    throws -> RecoveryAccountRecord
  {
    guard validName(username) else {
      throw AccountSetupFailure("Choose a lowercase recovery username.")
    }
    try validatePassword(password)
    let ctx = try context(target, writable: true)
    var record: RecoveryAccountRecord
    if let saved = try inspect(target) {
      guard saved.username == username else {
        throw AccountSetupFailure(
          "This installation already has a different recovery account. Use its name to resume.")
      }
      record = saved
    } else {
      guard try users(target).isEmpty else {
        throw AccountSetupFailure(
          "This installation already has APFS users and needs an existing-account recovery flow.")
      }
      let base = ctx.data.appendingPathComponent("private/var/db/dslocal")
      if FileManager.default.fileExists(atPath: base.path) {
        guard try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty else {
          throw AccountSetupFailure(
            "An existing target account database was preserved. It cannot be overwritten.")
        }
      }
      record = RecoveryAccountRecord(
        target: target, username: username, generatedUID: UUID().uuidString, phase: "creating")
      try save(record, ctx)
    }
    let path = ctx.database.appendingPathComponent("users/\(username).plist")
    var status = stat()
    let exists = lstat(path.path, &status) == 0
    guard exists || errno == ENOENT else {
      throw AccountSetupFailure("The target account could not be inspected.")
    }
    let existing = exists ? try user(ctx, username) : nil
    if let existing {
      guard existing["generateduid"] as? [String] == [record.generatedUID] else {
        throw AccountSetupFailure("The account UUID changed. Its existing data has been preserved.")
      }
    }
    if record.phase == "creating" {
      for url in [
        ctx.database.deletingLastPathComponent().deletingLastPathComponent(),
        ctx.database.deletingLastPathComponent(),
        ctx.database, ctx.database.appendingPathComponent("users"),
        ctx.database.appendingPathComponent("groups"),
      ] {
        try directory(url)
        guard chown(url.path, 0, 0) == 0, chmod(url.path, 0o700) == 0 else {
          throw AccountSetupFailure("Couldn’t protect the native account database.")
        }
      }
      let name = "/Local/Target/Users/\(username)"
      for (key, value) in [
        ("UniqueID", "501"), ("PrimaryGroupID", "20"), ("GeneratedUID", record.generatedUID),
        ("RealName", "Omarchy Recovery"), ("NFSHomeDirectory", "/Users/\(username)"),
        ("UserShell", "/bin/zsh"),
      ] {
        _ = try ds(ctx, ["-create", name, key, value])
      }
      for (group, gid) in [("staff", "20"), ("admin", "80")] {
        let groupPath = "/Local/Target/Groups/\(group)"
        _ = try ds(ctx, ["-create", groupPath, "PrimaryGroupID", gid])
        _ = try ds(ctx, ["-create", groupPath, "RealName", group])
        _ = try ds(ctx, ["-merge", groupPath, "GroupMembership", username])
        _ = try ds(ctx, ["-merge", groupPath, "GroupMembers", record.generatedUID])
      }
      if (existing?["ShadowHashData"] as? [Data] ?? []).isEmpty {
        _ = try ds(ctx, ["-create", name, "AuthenticationAuthority", ";DisabledTags;SecureToken"])
        var input = password
        input.append(10)
        _ = try ds(ctx, ["-passwd", name], input: input)
      }
      guard try authenticate(ctx, username, password),
        try !authenticate(ctx, username, Data(UUID().uuidString.utf8))
      else {
        throw AccountSetupFailure(
          "The recovery password did not verify. Enter the same password to resume.")
      }
      let authority = try ds(ctx, ["-read", name, "AuthenticationAuthority"])
      if authority.contains(";DisabledTags;SecureToken") {
        _ = try ds(ctx, ["-delete", name, "AuthenticationAuthority", ";DisabledTags;SecureToken"])
      }
      try waitForUser(ctx, record)
      let home = ctx.data.appendingPathComponent("Users/\(username)")
      try directory(home)
      guard chown(home.path, 501, 20) == 0 else {
        throw AccountSetupFailure("Couldn’t prepare the recovery account’s home.")
      }
    }
    guard try authenticate(ctx, username, password),
      try !authenticate(ctx, username, Data(UUID().uuidString.utf8))
    else {
      throw AccountSetupFailure(
        "The recovery password did not verify. Enter the password for this account again.")
    }
    let current = try user(ctx, username)
    guard current["generateduid"] as? [String] == [record.generatedUID],
      current["uid"] as? [String] == ["501"], current["gid"] as? [String] == ["20"]
    else { throw AccountSetupFailure("The native recovery account identity did not verify.") }
    for group in ["staff", "admin"] {
      let bytes = try protectedRead(
        ctx.database.appendingPathComponent("groups/\(group).plist"), limit: 1 << 20)
      guard
        let item = try PropertyListSerialization.propertyList(from: bytes, format: nil)
          as? [String: Any],
        (item["users"] as? [String] ?? []).contains(username),
        (item["groupmembers"] as? [String] ?? []).contains(record.generatedUID)
      else {
        throw AccountSetupFailure(
          "Recovery administrator membership has not finished saving. Continue again to resume.")
      }
    }
    try prepareLookup(ctx)
    if record.phase == "creating" { record.phase = "prepared" }
    try save(record, ctx)
    return record
  }

  static func prepareLookup(_ ctx: Context) throws {
    // Resolve both UUIDs on every invocation. Suffixes and renames must never
    // redirect the database to another installation. Recovery repeats this
    // repair before reading the selected account.
    let relative = relativePath(
      from: ctx.system, to: ctx.data.appendingPathComponent("private/var"))
    for link in [
      ctx.system.appendingPathComponent("var"), ctx.system.appendingPathComponent("private/var"),
    ] {
      try directory(link.deletingLastPathComponent())
      var status = stat()
      if lstat(link.path, &status) == 0 {
        if status.st_mode & S_IFMT == S_IFLNK {
          if try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            == relativePath(
              from: link.deletingLastPathComponent(),
              to: ctx.data.appendingPathComponent("private/var"))
          {
            continue
          }
          try FileManager.default.removeItem(at: link)
        } else {
          guard status.st_mode & S_IFMT == S_IFDIR,
            try FileManager.default.contentsOfDirectory(atPath: link.path).isEmpty
          else {
            throw AccountSetupFailure(
              "An existing System account path was preserved; it cannot be replaced.")
          }
          try FileManager.default.removeItem(at: link)
        }
      }
      try FileManager.default.createSymbolicLink(
        atPath: link.path,
        withDestinationPath: link.lastPathComponent == "var"
          && link.deletingLastPathComponent() == ctx.system
          ? relative
          : relativePath(
            from: link.deletingLastPathComponent(),
            to: ctx.data.appendingPathComponent("private/var")))
    }
  }

  public static func relativePath(from origin: URL, to target: URL) -> String {
    let a = origin.standardizedFileURL.pathComponents
    let b = target.standardizedFileURL.pathComponents
    var common = 0
    while common < min(a.count, b.count), a[common] == b[common] { common += 1 }
    return (Array(repeating: "..", count: a.count - common) + Array(b.dropFirst(common))).joined(
      separator: "/")
  }

  public static func finalize(_ target: RecoveryAccountTarget, password: Data) throws
    -> RecoveryAccountRecord
  {
    try validatePassword(password)
    let ctx = try context(target, writable: true)
    guard var record = try inspect(target) else {
      throw AccountSetupFailure("Create the recovery account before authorizing it.")
    }
    guard try authenticate(ctx, record.username, password),
      (try user(ctx, record.username))["generateduid"] as? [String] == [record.generatedUID]
    else { throw AccountSetupFailure("Enter the recovery account’s password to resume.") }
    try prepareLookup(ctx)
    let candidates = try users(target)
    guard
      let crypto = candidates.first(where: {
        ($0["APFSCryptoUserUUID"] as? String)?.uppercased() == record.generatedUID
      })
    else { return record }
    let account = try user(ctx, record.username)
    let authorities = account["authentication_authority"] as? [String] ?? []
    if !authorities.contains(";SecureToken;") {
      var secret = password
      secret.append(10)
      let args = [
        "apfs", "unlockVolume", target.dataUUID, "-user", record.generatedUID, "-verify",
        "-stdinpassphrase",
      ]
      let verified = try AccountNativeCommand.run("/usr/sbin/diskutil", args, input: secret)
      let rejected = try AccountNativeCommand.run(
        "/usr/sbin/diskutil", args, input: Data((UUID().uuidString + "\n").utf8))
      guard verified.status == 0,
        String(decoding: verified.output, as: UTF8.self).contains("Passphrase valid"),
        rejected.status != 0
      else {
        throw AccountSetupFailure(
          "The matching APFS credential could not be verified. Account metadata was preserved.")
      }
      let source = ctx.database.appendingPathComponent("users/\(record.username).plist")
      let backup = ctx.data.appendingPathComponent(
        "private/var/db/omarchy-recovery-account/backups/\(UUID().uuidString)")
      try directory(backup)
      try FileManager.default.copyItem(at: source, to: backup.appendingPathComponent("user.plist"))
      _ = try ds(
        ctx,
        [
          "-merge", "/Local/Target/Users/\(record.username)", "AuthenticationAuthority",
          ";SecureToken;",
        ])
      let updated = try user(ctx, record.username)
      guard (updated["authentication_authority"] as? [String] ?? []).contains(";SecureToken;"),
        updated["ShadowHashData"] as? [Data] == account["ShadowHashData"] as? [Data]
      else { throw AccountSetupFailure("The conditional credential repair did not verify.") }
      record.tokenReconciled = true
      try save(record, ctx)
    }
    guard crypto["VolumeOwner"] as? Bool == true else {
      record.phase = "awaiting-ownership"
      try save(record, ctx)
      return record
    }
    if record.phase != "finalized" {
      let backup = ctx.data.appendingPathComponent(
        "private/var/db/omarchy-recovery-account/backups/\(UUID().uuidString)")
      try directory(backup)
      for name in [
        "AdminUserRecoveryInfo.plist", "AllUsersInfo.plist", "CryptoUserInfo.plist",
        "secureaccesstoken.plist",
      ] {
        let file = ctx.metadata.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) {
          try FileManager.default.copyItem(at: file, to: backup.appendingPathComponent(name))
          _ = try AccountNativeCommand.checked("/bin/chflags", ["noschg", file.path])
        }
      }
      _ = try AccountNativeCommand.checked(
        "/usr/sbin/diskutil", ["apfs", "updatePreboot", target.dataUUID, "-od", ctx.database.path],
        timeout: 90)
    }
    let adminBytes = try protectedRead(
      ctx.metadata.appendingPathComponent("AdminUserRecoveryInfo.plist"), limit: 4 << 20)
    guard
      let admins = try PropertyListSerialization.propertyList(from: adminBytes, format: nil)
        as? [String: Any],
      let selected = admins[record.username] as? [String: Any],
      (selected["GeneratedUID"] as? String)?.uppercased() == record.generatedUID
    else {
      throw AccountSetupFailure("Recovery user metadata has not been generated for this account.")
    }
    for name in ["AllUsersInfo.plist", "CryptoUserInfo.plist"] {
      let bytes = try protectedRead(ctx.metadata.appendingPathComponent(name), limit: 4 << 20)
      let value = try PropertyListSerialization.propertyList(from: bytes, format: nil)
      guard containsUUID(value, record.generatedUID) else {
        throw AccountSetupFailure("Recovery’s \(name) is missing the new owner.")
      }
    }
    let source = ctx.database.appendingPathComponent("secureaccesstoken.plist")
    let token = try protectedRead(source, limit: 1 << 20)
    guard
      let values = try PropertyListSerialization.propertyList(from: token, format: nil)
        as? [String: Any],
      let wrapped = values["SecureAccessToken"] as? Data, !wrapped.isEmpty
    else {
      throw AccountSetupFailure("The target’s native Recovery disk token is not available yet.")
    }
    let destination = ctx.metadata.appendingPathComponent("secureaccesstoken.plist")
    try token.write(to: destination, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: destination.path)
    guard chown(destination.path, 0, 0) == 0,
      try protectedRead(destination, limit: 1 << 20) == token
    else { throw AccountSetupFailure("Recovery’s native disk token did not verify.") }
    guard
      try users(target).contains(where: {
        ($0["APFSCryptoUserUUID"] as? String)?.uppercased() == record.generatedUID
          && $0["VolumeOwner"] as? Bool == true
      })
    else { throw AccountSetupFailure("Recovery ownership changed during finalization.") }
    record.phase = "finalized"
    try save(record, ctx)
    return record
  }

  public static func requireOwnership(_ record: RecoveryAccountRecord) throws {
    guard record.phase == "finalized",
      try users(record.target).contains(where: {
        ($0["APFSCryptoUserUUID"] as? String)?.uppercased() == record.generatedUID
          && $0["VolumeOwner"] as? Bool == true
      })
    else {
      throw AccountSetupFailure(
        "Authorize \(record.username) in Startup Disk first. Select \(record.target.volumeName), click Restart, and choose Authorize Users."
      )
    }
  }

  static func containsUUID(_ value: Any, _ expected: String) -> Bool {
    if let text = value as? String { return text.uppercased() == expected }
    if let array = value as? [Any] { return array.contains { containsUUID($0, expected) } }
    if let dictionary = value as? [String: Any] {
      return dictionary.contains {
        $0.key.uppercased() == expected || containsUUID($0.value, expected)
      }
    }
    return false
  }
}
