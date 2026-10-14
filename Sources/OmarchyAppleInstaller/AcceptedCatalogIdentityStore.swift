#if os(macOS)
  import Darwin
  import Foundation

  public enum AcceptedCatalogIdentityStoreError:
    Error, Equatable, Sendable
  {
    case unsafeDirectory
    case unsafeState
    case writeFailed
  }

  public struct AcceptedCatalogIdentityStore: Sendable {
    /// State files of the MX Mac installer, which shared this workspace while
    /// both used the same app identifier. They hold another stream's floors,
    /// so this stream never reads, writes or removes them.
    public static let mxMacFileNames = [
      "accepted-catalog.json",
      "accepted-catalog-stable.json",
      "accepted-catalog-rc.json",
      "accepted-catalog-rc-aurora.json",
    ]
    private static let maximumBytes: Int64 = 4_096

    private let directory: URL
    private let channel: ReleaseChannel

    public init(directory: URL, channel: ReleaseChannel) {
      self.directory = directory
      self.channel = channel
    }

    /// Each channel of this release stream keeps its own accepted sequence.
    /// Without this, a tester who accepted a rc catalog could never go back to
    /// stable: the older stable sequence would look like a rollback. The
    /// stream name keeps the MX Mac installer's floors, should they share a
    /// workspace, from blocking this stream's first catalogs and the other way
    /// round.
    public static func fileName(for channel: ReleaseChannel) -> String {
      "accepted-catalog-\(InstallerBuildConfiguration.streamPath)-\(channel.rawValue).json"
    }

    private var fileName: String {
      Self.fileName(for: channel)
    }

    public func load() throws -> AcceptedCatalogIdentity? {
      try validateDirectory()
      return try read(fileName: fileName)
    }

    private func read(fileName: String) throws -> AcceptedCatalogIdentity? {
      let stateURL = directory.appendingPathComponent(fileName)
      let descriptor = Darwin.open(
        stateURL.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
      )
      if descriptor < 0, errno == ENOENT {
        return nil
      }
      guard descriptor >= 0 else {
        throw AcceptedCatalogIdentityStoreError.unsafeState
      }
      defer { Darwin.close(descriptor) }

      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_mode & 0o077 == 0,
        status.st_size > 0,
        status.st_size <= Self.maximumBytes
      else {
        throw AcceptedCatalogIdentityStoreError.unsafeState
      }
      let handle = FileHandle(
        fileDescriptor: descriptor,
        closeOnDealloc: false
      )
      guard let data = try handle.readToEnd(),
        data.count == Int(status.st_size),
        let object = try? JSONSerialization.jsonObject(with: data),
        let dictionary = object as? [String: Any],
        Set(dictionary.keys) == [
          "schema_version",
          "sequence",
          "payload_digest",
        ],
        let record = try? JSONDecoder().decode(
          StoredCatalogIdentity.self,
          from: data
        ),
        record.schemaVersion == 1,
        let identity = try? AcceptedCatalogIdentity(
          sequence: record.sequence,
          payloadDigest: record.payloadDigest
        )
      else {
        throw AcceptedCatalogIdentityStoreError.unsafeState
      }
      return identity
    }

    public func store(_ identity: AcceptedCatalogIdentity) throws {
      if let existing = try load() {
        guard identity.sequence >= existing.sequence else {
          throw SupportCatalogSequenceError.rollback(
            stored: existing.sequence,
            candidate: identity.sequence
          )
        }
        guard
          identity.sequence != existing.sequence
            || identity.payloadDigest == existing.payloadDigest
        else {
          throw SupportCatalogSequenceError.sequenceReuse(identity.sequence)
        }
        if identity == existing {
          return
        }
      }

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(StoredCatalogIdentity(identity))
      guard data.count <= Self.maximumBytes else {
        throw AcceptedCatalogIdentityStoreError.writeFailed
      }

      let pending = directory.appendingPathComponent(
        ".\(fileName)-\(UUID().uuidString.lowercased()).tmp"
      )
      let descriptor = Darwin.open(
        pending.path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
      )
      guard descriptor >= 0 else {
        throw AcceptedCatalogIdentityStoreError.writeFailed
      }
      var isOpen = true
      defer {
        if isOpen {
          Darwin.close(descriptor)
        }
        try? FileManager.default.removeItem(at: pending)
      }

      do {
        let handle = FileHandle(
          fileDescriptor: descriptor,
          closeOnDealloc: false
        )
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        isOpen = false
      } catch {
        throw AcceptedCatalogIdentityStoreError.writeFailed
      }

      let destination = directory.appendingPathComponent(fileName)
      guard Darwin.rename(pending.path, destination.path) == 0 else {
        throw AcceptedCatalogIdentityStoreError.writeFailed
      }
      try synchronizeDirectory()
    }

    private func validateDirectory() throws {
      var status = stat()
      guard lstat(directory.path, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFDIR,
        status.st_mode & 0o077 == 0
      else {
        throw AcceptedCatalogIdentityStoreError.unsafeDirectory
      }
    }

    private func synchronizeDirectory() throws {
      let descriptor = Darwin.open(
        directory.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else {
        throw AcceptedCatalogIdentityStoreError.writeFailed
      }
      defer { Darwin.close(descriptor) }
      guard fsync(descriptor) == 0 else {
        throw AcceptedCatalogIdentityStoreError.writeFailed
      }
    }
  }

  private struct StoredCatalogIdentity: Codable {
    let schemaVersion: Int
    let sequence: UInt64
    let payloadDigest: String

    init(_ identity: AcceptedCatalogIdentity) {
      schemaVersion = 1
      sequence = identity.sequence
      payloadDigest = identity.payloadDigest
    }

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case sequence
      case payloadDigest = "payload_digest"
    }
  }
#endif
