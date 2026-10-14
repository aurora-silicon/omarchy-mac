import Darwin
import Foundation
import RecoveryAuthorization

/// The installed Omarchy volumes the macOS-side Recovery handoff works on.
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
      else { throw AccountSetupFailure("The installation target is invalid.") }
    }
    guard Set([systemUUID, dataUUID, prebootUUID]).count == 3,
      !volumeName.isEmpty, volumeName.count <= 80, !volumeName.contains("/")
    else { throw AccountSetupFailure("The installation target is invalid.") }
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
  public static func volumeGroupUUID(device: String) throws -> String? {
    var buffer = [CChar](repeating: 0, count: 37)
    let status = buffer.withUnsafeMutableBufferPointer {
      omarchy_apfs_volume_group_uuid(device, $0.baseAddress, $0.count)
    }
    // The native reader returns this when the mounted-volume registry has no
    // group property yet. diskutil can infer a group and mask this condition.
    if status == 0xc002 { return nil }
    guard status == 0 else {
      throw AccountSetupFailure("Couldn’t read the mounted APFS group metadata.")
    }
    return String(cString: buffer)
  }

  public static func run(
    _ executable: String, _ arguments: [String], input: Data = Data(), timeout: UInt32 = 60
  ) throws -> AccountCommandResult {
    guard input.count <= 8192 else {
      throw AccountSetupFailure("The supplied command input is too long.")
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
        "The native \(URL(fileURLWithPath: executable).lastPathComponent) command could not finish (status \(status)). Your installation has been preserved."
      )
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
        "\(URL(fileURLWithPath: executable).lastPathComponent) failed (status \(result.status))."
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
      throw AccountSetupFailure("Couldn’t identify the installation volume.")
    }
    return value
  }
}

public enum RecoveryAccountInstaller {
  public static func refreshMountedGroup(_ target: RecoveryAccountTarget) throws {
    try target.validate()
    guard geteuid() == 0,
      (try AccountNativeCommand.disk("/")["APFSVolumeGroupID"] as? String)?.uppercased()
        != target.groupUUID,
      (try AccountNativeCommand.disk(target.systemUUID)["APFSVolumeGroupID"] as? String)?
        .uppercased() == target.groupUUID
    else {
      throw AccountSetupFailure("The running system cannot be refreshed as an installation target.")
    }
    let before = try AccountNativeCommand.disk(target.dataUUID)
    guard (before["VolumeUUID"] as? String)?.uppercased() == target.dataUUID,
      (before["APFSVolumeGroupID"] as? String)?.uppercased() == target.groupUUID,
      let device = before["DeviceIdentifier"] as? String,
      device.range(of: "\\Adisk[0-9]+s[0-9]+\\z", options: .regularExpression) != nil
    else { throw AccountSetupFailure("The Data volume does not match the installation.") }
    let mountedGroup = try AccountNativeCommand.volumeGroupUUID(device: "/dev/" + device)
    if mountedGroup == target.groupUUID { return }
    guard mountedGroup == nil else {
      throw AccountSetupFailure("The mounted Data volume belongs to a different group.")
    }
    // The Data volume is mounted before Asahi creates its paired System
    // volume. A normal remount refreshes the group property StorageKit reads.
    // Never force an unmount or change an on-disk group UUID.
    _ = try AccountNativeCommand.checked("/usr/sbin/diskutil", ["unmount", device])
    _ = try AccountNativeCommand.checked("/usr/sbin/diskutil", ["mount", device])
    let after = try AccountNativeCommand.disk(target.dataUUID)
    guard (after["VolumeUUID"] as? String)?.uppercased() == target.dataUUID,
      (after["APFSVolumeGroupID"] as? String)?.uppercased() == target.groupUUID,
      try AccountNativeCommand.volumeGroupUUID(device: "/dev/" + device) == target.groupUUID
    else {
      throw AccountSetupFailure(
        "The mounted APFS group metadata did not refresh. Your installation was preserved.")
    }
  }

  public static func protectedRead(_ path: URL, limit: Int) throws -> Data {
    let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
      throw AccountSetupFailure("A protected installation record could not be read.")
    }
    var status = stat()
    guard fstat(fd, &status) == 0, status.st_uid == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_mode & 0o022 == 0, status.st_size > 0, status.st_size <= limit
    else {
      close(fd)
      throw AccountSetupFailure("A protected installation record is unsuitable.")
    }
    return try FileHandle(fileDescriptor: fd, closeOnDealloc: true).readToEnd() ?? Data()
  }
}
