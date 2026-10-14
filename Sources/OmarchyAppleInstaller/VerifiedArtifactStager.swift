import CryptoKit
import Darwin
import Foundation

public struct PinnedArtifactPart: Equatable, Sendable {
  public let sourceURL: URL
  public let fileName: String
  public let expectedDigest: String
  public let expectedSizeBytes: UInt64

  public init(
    sourceURL: URL,
    fileName: String,
    expectedDigest: String,
    expectedSizeBytes: UInt64
  ) throws {
    guard sourceURL.scheme == "https",
      sourceURL.host?.isEmpty == false,
      sourceURL.user == nil,
      sourceURL.password == nil,
      sourceURL.fragment == nil
    else {
      throw ArtifactStageError.invalidSourceURL
    }
    guard PinnedInstallerArtifact.isSafeFileName(fileName) else {
      throw ArtifactStageError.invalidFileName
    }
    guard SHA256Digest(rawValue: expectedDigest) != nil else {
      throw ArtifactStageError.invalidDigest
    }
    guard expectedSizeBytes > 0 else {
      throw ArtifactStageError.invalidExpectedSize
    }

    self.sourceURL = sourceURL
    self.fileName = fileName
    self.expectedDigest = expectedDigest
    self.expectedSizeBytes = expectedSizeBytes
  }
}

public struct PinnedInstallerArtifact: Equatable, Sendable {
  public static let maximumPartCount = 16

  public let role: String
  public let sourceURL: URL
  public let fileName: String
  public let expectedDigest: String
  public let expectedSizeBytes: UInt64
  public let parts: [PinnedArtifactPart]

  public init(
    role: String,
    sourceURL: URL,
    fileName: String,
    expectedDigest: String,
    expectedSizeBytes: UInt64,
    parts: [PinnedArtifactPart] = []
  ) throws {
    guard !role.isEmpty, role.utf8.count <= 64 else {
      throw ArtifactStageError.invalidRole
    }
    guard sourceURL.scheme == "https",
      sourceURL.host?.isEmpty == false,
      sourceURL.user == nil,
      sourceURL.password == nil,
      sourceURL.fragment == nil
    else {
      throw ArtifactStageError.invalidSourceURL
    }
    guard Self.isSafeFileName(fileName) else {
      throw ArtifactStageError.invalidFileName
    }
    guard SHA256Digest(rawValue: expectedDigest) != nil else {
      throw ArtifactStageError.invalidDigest
    }
    guard expectedSizeBytes > 0 else {
      throw ArtifactStageError.invalidExpectedSize
    }
    if !parts.isEmpty {
      try Self.validate(
        parts: parts,
        wholeFileName: fileName,
        wholeSizeBytes: expectedSizeBytes
      )
    }

    self.role = role
    self.sourceURL = sourceURL
    self.fileName = fileName
    self.expectedDigest = expectedDigest
    self.expectedSizeBytes = expectedSizeBytes
    self.parts = parts
  }

  private static func validate(
    parts: [PinnedArtifactPart],
    wholeFileName: String,
    wholeSizeBytes: UInt64
  ) throws {
    guard (2...maximumPartCount).contains(parts.count) else {
      throw ArtifactStageError.invalidPartCount(parts.count)
    }

    var seenFileNames = Set<String>()
    var declaredBytes: UInt64 = 0
    for part in parts {
      guard part.fileName != wholeFileName else {
        throw ArtifactStageError.invalidPartFileName(part.fileName)
      }
      guard seenFileNames.insert(part.fileName).inserted else {
        throw ArtifactStageError.invalidPartFileName(part.fileName)
      }
      let sum = declaredBytes.addingReportingOverflow(part.expectedSizeBytes)
      guard !sum.overflow else {
        throw ArtifactStageError.partSizeSumMismatch(
          expected: wholeSizeBytes,
          actual: UInt64.max
        )
      }
      declaredBytes = sum.partialValue
    }
    guard declaredBytes == wholeSizeBytes else {
      throw ArtifactStageError.partSizeSumMismatch(
        expected: wholeSizeBytes,
        actual: declaredBytes
      )
    }
  }

  static func isSafeFileName(_ value: String) -> Bool {
    !value.isEmpty
      && value != "."
      && value != ".."
      && value.utf8.count <= 255
      && !value.utf8.contains(0)
      && !value.contains("/")
      && !value.contains("\\")
      && (value as NSString).lastPathComponent == value
  }

}

public struct StagedInstallerArtifact: Equatable, Sendable {
  public let artifact: PinnedInstallerArtifact
  public let fileURL: URL
  public let reusedExistingFile: Bool
  public let materialization: ArtifactMaterialization

  public init(
    artifact: PinnedInstallerArtifact,
    fileURL: URL,
    reusedExistingFile: Bool,
    materialization: ArtifactMaterialization? = nil
  ) {
    self.artifact = artifact
    self.fileURL = fileURL
    self.reusedExistingFile = reusedExistingFile
    self.materialization =
      materialization
      ?? (reusedExistingFile ? .reusedExistingFile : .atomicRename)
  }
}

public enum ArtifactMaterialization: String, Equatable, Sendable {
  case reusedExistingFile
  case atomicRename
  case verifiedCopyFallback
  case assembledFromParts
}

public struct ArtifactStagingProgress: Equatable, Sendable {
  public enum Phase: String, Equatable, Sendable {
    case downloading
    case assembling
    case verified
  }

  public let role: String
  public let fileName: String
  public let phase: Phase
  public let partIndex: Int?
  public let partCount: Int?
  public let bytesCompleted: UInt64
  public let totalBytes: UInt64

  public init(
    role: String,
    fileName: String,
    phase: Phase,
    partIndex: Int? = nil,
    partCount: Int? = nil,
    bytesCompleted: UInt64,
    totalBytes: UInt64
  ) {
    self.role = role
    self.fileName = fileName
    self.phase = phase
    self.partIndex = partIndex
    self.partCount = partCount
    self.bytesCompleted = bytesCompleted
    self.totalBytes = totalBytes
  }
}

public typealias ArtifactStagingProgressHandler =
  @Sendable (
    ArtifactStagingProgress
  ) -> Void

public enum ArtifactStageError: Error, Equatable, Sendable {
  case invalidRole
  case invalidSourceURL
  case invalidFileName
  case invalidDigest
  case invalidExpectedSize
  case invalidPartCount(Int)
  case invalidPartFileName(String)
  case partSizeSumMismatch(expected: UInt64, actual: UInt64)
  case unsafeStagingDirectory
  case unsafeStagedFile(String)
  case unexpectedHTTPStatus(Int)
  case sizeMismatch(expected: UInt64, actual: UInt64)
  case digestMismatch(expected: String, actual: String)
  case destinationConflict(String)
  case bundledArtifactMissing(String)
}

/// Stages pinned artifacts into a private directory, accepting bytes only when
/// the whole-file size and digest match the signed catalog.
///
/// Multi-part payloads are downloaded part by part, then streamed together into
/// a single pending file whose SHA-256 is computed in the same pass. Assembly
/// therefore needs about twice the payload size on disk until the parts are
/// deleted. Within one run a dropped connection resumes at byte granularity
/// (see `RangedArtifactDownloader`); across runs, at part granularity.
public struct VerifiedArtifactStager: Sendable {
  /// Disk room required while a payload is assembled from parts (payload plus
  /// the pending concatenation) before the parts are deleted.
  public static func requiredFreeBytes(forPayloadSize size: UInt64) -> UInt64 {
    let (doubled, overflow) = size.multipliedReportingOverflow(by: 2)
    return overflow ? UInt64.max : doubled
  }

  /// Resume check: verified parts already occupy space, so only the remaining
  /// payload bytes plus assembly headroom are required — never 2× again.
  public static func requiredFreeBytes(
    forPayloadSize size: UInt64,
    alreadyOnDisk: UInt64
  ) -> UInt64 {
    let total = requiredFreeBytes(forPayloadSize: size)
    return total > alreadyOnDisk ? total - alreadyOnDisk : 0
  }

  private static let chunkBytes = 1_048_576

  private let downloader: any ArtifactDownloading
  private let promoter: AtomicArtifactFilePromoter
  private let bundledEngineDirectory: URL?
  private let bundledArtifactDirectory: URL?
  private let requiresBundledArtifacts: Bool

  public init() {
    downloader = RangedArtifactDownloader()
    promoter = AtomicArtifactFilePromoter()
    bundledEngineDirectory = Bundle.main.resourceURL?.appendingPathComponent("Engine/artifacts")
    bundledArtifactDirectory = Bundle.main.resourceURL?.appendingPathComponent("Artifacts")
    requiresBundledArtifacts =
      Bundle.main.object(forInfoDictionaryKey: "OmarchyOfflineBundle") as? Bool == true
  }

  init(
    downloader: any ArtifactDownloading,
    promoter: AtomicArtifactFilePromoter = AtomicArtifactFilePromoter(),
    bundledEngineDirectory: URL? = nil,
    bundledArtifactDirectory: URL? = nil,
    requiresBundledArtifacts: Bool = false
  ) {
    self.downloader = downloader
    self.promoter = promoter
    self.bundledEngineDirectory = bundledEngineDirectory
    self.bundledArtifactDirectory = bundledArtifactDirectory
    self.requiresBundledArtifacts = requiresBundledArtifacts
  }

  public func matches(_ artifact: PinnedInstallerArtifact, at fileURL: URL) -> Bool {
    (try? verify(artifact, at: fileURL)) != nil
  }

  public func requiresNetwork(for artifact: PinnedInstallerArtifact) -> Bool {
    !requiresBundledArtifacts && bundledSource(for: artifact) == nil
  }

  private func bundledSource(for artifact: PinnedInstallerArtifact) -> URL? {
    var directories = [bundledArtifactDirectory].compactMap { $0 }
    if artifact.role == "engine", artifact.parts.isEmpty, let bundledEngineDirectory {
      directories.append(bundledEngineDirectory)
    }
    return directories.map { $0.appendingPathComponent(artifact.fileName) }
      .first { FileManager.default.fileExists(atPath: $0.path) }
  }

  public func stage(
    _ artifact: PinnedInstallerArtifact,
    in stagingDirectory: URL,
    progress: ArtifactStagingProgressHandler? = nil
  ) async throws -> StagedInstallerArtifact {
    try Task.checkCancellation()
    let fileManager = FileManager.default
    try ensureSafeDirectory(stagingDirectory, fileManager: fileManager)
    let destination = stagingDirectory.appendingPathComponent(
      artifact.fileName,
      isDirectory: false
    )

    if fileManager.fileExists(atPath: destination.path) {
      do {
        try verify(artifact, at: destination)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw ArtifactStageError.destinationConflict(artifact.fileName)
      }
      removeParts(of: artifact, in: stagingDirectory, fileManager: fileManager)
      report(
        progress,
        artifact: artifact,
        phase: .verified,
        bytesCompleted: artifact.expectedSizeBytes
      )
      return StagedInstallerArtifact(
        artifact: artifact,
        fileURL: destination,
        reusedExistingFile: true,
        materialization: .reusedExistingFile
      )
    }

    if let source = bundledSource(for: artifact) {
      // Every bundled artifact must match the authenticated catalog exactly.
      try verify(artifact, at: source)
      try Task.checkCancellation()
      let pending = stagingDirectory.appendingPathComponent(".pending-\(UUID().uuidString)")
      defer { try? fileManager.removeItem(at: pending) }
      try fileManager.copyItem(at: source, to: pending)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
      try verify(artifact, at: pending)
      try Task.checkCancellation()
      try fileManager.moveItem(at: pending, to: destination)
      removeParts(of: artifact, in: stagingDirectory, fileManager: fileManager)
      report(
        progress, artifact: artifact, phase: .verified, bytesCompleted: artifact.expectedSizeBytes)
      return StagedInstallerArtifact(
        artifact: artifact, fileURL: destination, reusedExistingFile: false,
        materialization: .verifiedCopyFallback
      )
    }

    guard !requiresBundledArtifacts else {
      throw ArtifactStageError.bundledArtifactMissing(artifact.fileName)
    }

    guard !artifact.parts.isEmpty else {
      let onBytes = byteHandler(
        progress,
        artifact: artifact,
        partIndex: nil,
        partSizeBytes: artifact.expectedSizeBytes,
        completedBytes: 0
      )
      let staged = try await stageSingle(
        url: artifact.sourceURL,
        fileName: artifact.fileName,
        expectedDigest: artifact.expectedDigest,
        expectedSizeBytes: artifact.expectedSizeBytes,
        in: stagingDirectory,
        onBytes: onBytes
      )
      report(
        progress,
        artifact: artifact,
        phase: .verified,
        bytesCompleted: artifact.expectedSizeBytes
      )
      return StagedInstallerArtifact(
        artifact: artifact,
        fileURL: staged.fileURL,
        reusedExistingFile: staged.reused,
        materialization: staged.materialization
      )
    }

    return try await stageParts(
      artifact,
      in: stagingDirectory,
      destination: destination,
      progress: progress
    )
  }

  private func stageParts(
    _ artifact: PinnedInstallerArtifact,
    in stagingDirectory: URL,
    destination: URL,
    progress: ArtifactStagingProgressHandler?
  ) async throws -> StagedInstallerArtifact {
    try Task.checkCancellation()
    let fileManager = FileManager.default
    var partFileURLs = [URL]()
    var completedBytes: UInt64 = 0

    for (index, part) in artifact.parts.enumerated() {
      let onBytes = byteHandler(
        progress,
        artifact: artifact,
        partIndex: index,
        partSizeBytes: part.expectedSizeBytes,
        completedBytes: completedBytes
      )
      let staged = try await stageSingle(
        url: part.sourceURL,
        fileName: part.fileName,
        expectedDigest: part.expectedDigest,
        expectedSizeBytes: part.expectedSizeBytes,
        in: stagingDirectory,
        onBytes: onBytes
      )
      partFileURLs.append(staged.fileURL)
      completedBytes += part.expectedSizeBytes
      report(
        progress,
        artifact: artifact,
        phase: .downloading,
        partIndex: index,
        bytesCompleted: completedBytes
      )
    }

    report(
      progress,
      artifact: artifact,
      phase: .assembling,
      bytesCompleted: completedBytes
    )

    let pending = stagingDirectory.appendingPathComponent(
      ".pending-\(UUID().uuidString.lowercased())",
      isDirectory: false
    )
    defer { try? fileManager.removeItem(at: pending) }

    try assemble(
      parts: partFileURLs,
      into: pending,
      expectedDigest: artifact.expectedDigest,
      expectedSizeBytes: artifact.expectedSizeBytes
    )

    try Task.checkCancellation()
    do {
      try fileManager.moveItem(at: pending, to: destination)
    } catch {
      guard fileManager.fileExists(atPath: destination.path) else {
        throw error
      }
      do {
        try verify(artifact, at: destination)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw ArtifactStageError.destinationConflict(artifact.fileName)
      }
    }

    for partFileURL in partFileURLs {
      try? fileManager.removeItem(at: partFileURL)
    }
    report(
      progress,
      artifact: artifact,
      phase: .verified,
      bytesCompleted: artifact.expectedSizeBytes
    )

    return StagedInstallerArtifact(
      artifact: artifact,
      fileURL: destination,
      reusedExistingFile: false,
      materialization: .assembledFromParts
    )
  }

  private func stageSingle(
    url: URL,
    fileName: String,
    expectedDigest: String,
    expectedSizeBytes: UInt64,
    in stagingDirectory: URL,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> (
    fileURL: URL, materialization: ArtifactMaterialization, reused: Bool
  ) {
    let fileManager = FileManager.default
    let destination = stagingDirectory.appendingPathComponent(
      fileName,
      isDirectory: false
    )

    if fileManager.fileExists(atPath: destination.path) {
      do {
        try verify(
          fileName: fileName,
          expectedDigest: expectedDigest,
          expectedSizeBytes: expectedSizeBytes,
          at: destination
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw ArtifactStageError.destinationConflict(fileName)
      }
      return (destination, .reusedExistingFile, true)
    }

    let downloaded = try await downloader.download(
      from: url,
      expectedSizeBytes: expectedSizeBytes,
      onBytes: onBytes
    )
    defer { try? fileManager.removeItem(at: downloaded) }

    let pending = stagingDirectory.appendingPathComponent(
      ".pending-\(UUID().uuidString.lowercased())",
      isDirectory: false
    )
    defer { try? fileManager.removeItem(at: pending) }

    try Task.checkCancellation()
    let materialization = try promoter.promote(
      source: downloaded,
      pending: pending
    )
    try verify(
      fileName: fileName,
      expectedDigest: expectedDigest,
      expectedSizeBytes: expectedSizeBytes,
      at: pending
    )

    try Task.checkCancellation()
    do {
      try fileManager.moveItem(at: pending, to: destination)
    } catch {
      guard fileManager.fileExists(atPath: destination.path) else {
        throw error
      }
      do {
        try verify(
          fileName: fileName,
          expectedDigest: expectedDigest,
          expectedSizeBytes: expectedSizeBytes,
          at: destination
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw ArtifactStageError.destinationConflict(fileName)
      }
    }

    return (destination, materialization, false)
  }

  private func assemble(
    parts: [URL],
    into destination: URL,
    expectedDigest: String,
    expectedSizeBytes: UInt64
  ) throws {
    try Task.checkCancellation()
    let fileManager = FileManager.default
    guard
      fileManager.createFile(
        atPath: destination.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw ArtifactStageError.unsafeStagedFile(destination.lastPathComponent)
    }

    let writer = try FileHandle(forWritingTo: destination)
    var hasher = SHA256()
    var size: UInt64 = 0

    do {
      for part in parts {
        let reader = try FileHandle(forReadingFrom: part)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: Self.chunkBytes),
          !chunk.isEmpty
        {
          try Task.checkCancellation()
          try writer.write(contentsOf: chunk)
          hasher.update(data: chunk)
          let total = size.addingReportingOverflow(UInt64(chunk.count))
          guard !total.overflow else {
            throw ArtifactStageError.invalidExpectedSize
          }
          size = total.partialValue
        }
      }
      try writer.close()
    } catch {
      try? writer.close()
      throw error
    }

    guard size == expectedSizeBytes else {
      throw ArtifactStageError.sizeMismatch(
        expected: expectedSizeBytes,
        actual: size
      )
    }
    let digest = SHA256Digest.prefixedHex(hasher.finalize())
    guard digest == expectedDigest else {
      throw ArtifactStageError.digestMismatch(
        expected: expectedDigest,
        actual: digest
      )
    }
  }

  private func removeParts(
    of artifact: PinnedInstallerArtifact,
    in stagingDirectory: URL,
    fileManager: FileManager
  ) {
    for part in artifact.parts {
      try? fileManager.removeItem(
        at: stagingDirectory.appendingPathComponent(
          part.fileName,
          isDirectory: false
        )
      )
    }
  }

  private func byteHandler(
    _ handler: ArtifactStagingProgressHandler?,
    artifact: PinnedInstallerArtifact,
    partIndex: Int?,
    partSizeBytes: UInt64,
    completedBytes: UInt64
  ) -> ArtifactByteProgressHandler? {
    guard let handler else {
      return nil
    }
    let role = artifact.role
    let fileName = artifact.fileName
    let partCount = artifact.parts.isEmpty ? nil : artifact.parts.count
    let totalBytes = artifact.expectedSizeBytes
    return { bytesReceived in
      handler(
        ArtifactStagingProgress(
          role: role,
          fileName: fileName,
          phase: .downloading,
          partIndex: partIndex,
          partCount: partCount,
          bytesCompleted: completedBytes + min(bytesReceived, partSizeBytes),
          totalBytes: totalBytes
        )
      )
    }
  }

  private func report(
    _ handler: ArtifactStagingProgressHandler?,
    artifact: PinnedInstallerArtifact,
    phase: ArtifactStagingProgress.Phase,
    partIndex: Int? = nil,
    bytesCompleted: UInt64
  ) {
    guard let handler else {
      return
    }
    handler(
      ArtifactStagingProgress(
        role: artifact.role,
        fileName: artifact.fileName,
        phase: phase,
        partIndex: partIndex,
        partCount: artifact.parts.isEmpty ? nil : artifact.parts.count,
        bytesCompleted: bytesCompleted,
        totalBytes: artifact.expectedSizeBytes
      )
    )
  }

  private func ensureSafeDirectory(
    _ directory: URL,
    fileManager: FileManager
  ) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(
      atPath: directory.path,
      isDirectory: &isDirectory
    ) {
      let values = try directory.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      )
      guard isDirectory.boolValue,
        values.isDirectory == true,
        values.isSymbolicLink != true
      else {
        throw ArtifactStageError.unsafeStagingDirectory
      }
      return
    }

    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let values = try directory.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw ArtifactStageError.unsafeStagingDirectory
    }
  }

  private func verify(
    _ artifact: PinnedInstallerArtifact,
    at fileURL: URL
  ) throws {
    try verify(
      fileName: artifact.fileName,
      expectedDigest: artifact.expectedDigest,
      expectedSizeBytes: artifact.expectedSizeBytes,
      at: fileURL
    )
  }

  private func verify(
    fileName: String,
    expectedDigest: String,
    expectedSizeBytes: UInt64,
    at fileURL: URL
  ) throws {
    let values = try fileURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw ArtifactStageError.unsafeStagedFile(fileName)
    }

    let result = try digestAndSize(of: fileURL)
    guard result.size == expectedSizeBytes else {
      throw ArtifactStageError.sizeMismatch(
        expected: expectedSizeBytes,
        actual: result.size
      )
    }
    guard result.digest == expectedDigest else {
      throw ArtifactStageError.digestMismatch(
        expected: expectedDigest,
        actual: result.digest
      )
    }
  }

  private func digestAndSize(
    of fileURL: URL
  ) throws -> (digest: String, size: UInt64) {
    try Task.checkCancellation()
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    var hasher = SHA256()
    var size: UInt64 = 0

    while let chunk = try handle.read(upToCount: Self.chunkBytes),
      !chunk.isEmpty
    {
      try Task.checkCancellation()
      let addition = UInt64(chunk.count)
      guard !size.addingReportingOverflow(addition).overflow else {
        throw ArtifactStageError.invalidExpectedSize
      }
      size += addition
      hasher.update(data: chunk)
    }

    let digest = SHA256Digest.prefixedHex(hasher.finalize())
    return (digest, size)
  }
}

enum ArtifactRenameResult: Equatable, Sendable {
  case success
  case failure(Int32)
}

struct AtomicArtifactFilePromoter: Sendable {
  private let renameOperation: @Sendable (URL, URL) -> ArtifactRenameResult

  init() {
    renameOperation = { source, destination in
      let result = source.path.withCString { sourcePath in
        destination.path.withCString { destinationPath in
          Darwin.rename(sourcePath, destinationPath)
        }
      }
      return result == 0 ? .success : .failure(Darwin.errno)
    }
  }

  init(
    renameOperation: @escaping @Sendable (URL, URL) -> ArtifactRenameResult
  ) {
    self.renameOperation = renameOperation
  }

  func promote(
    source: URL,
    pending: URL
  ) throws -> ArtifactMaterialization {
    switch renameOperation(source, pending) {
    case .success:
      return .atomicRename
    case .failure(EXDEV):
      try FileManager.default.copyItem(at: source, to: pending)
      return .verifiedCopyFallback
    case .failure(let code):
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
  }
}

public typealias ArtifactByteProgressHandler =
  @Sendable (
    _ bytesReceived: UInt64
  ) -> Void

protocol ArtifactDownloading: Sendable {
  func download(from sourceURL: URL) async throws -> URL
  func download(
    from sourceURL: URL,
    expectedSizeBytes: UInt64,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> URL
}

extension ArtifactDownloading {
  /// Bridges downloaders that only implement the unmetered form; the stager
  /// always calls the metered one.
  func download(
    from sourceURL: URL,
    expectedSizeBytes: UInt64,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> URL {
    try await download(from: sourceURL)
  }
}

/// Downloads one artifact per call over an ephemeral session, reporting
/// throttled byte counts and cancelling any transfer that exceeds the pinned
/// size.
final class ProgressReportingArtifactDownloader: NSObject, ArtifactDownloading,
  URLSessionDownloadDelegate, @unchecked Sendable
{
  private static let reportIntervalSeconds: TimeInterval = 0.25
  private static let reportByteInterval: UInt64 = 16 * 1_048_576
  private let configuration: URLSessionConfiguration

  init(configuration: URLSessionConfiguration = .ephemeral) {
    self.configuration = configuration
    super.init()
  }

  private struct Transfer {
    let continuation: CheckedContinuation<URL, any Error>
    let expectedSizeBytes: UInt64
    let onBytes: ArtifactByteProgressHandler?
    var lastReportedBytes: UInt64 = 0
    var lastReportedAt: Date?
    var failure: (any Error)?
  }

  private let lock = NSLock()
  private var transfers = [ObjectIdentifier: Transfer]()

  func download(from sourceURL: URL) async throws -> URL {
    try await download(
      from: sourceURL,
      expectedSizeBytes: UInt64.max,
      onBytes: nil
    )
  }

  func download(
    from sourceURL: URL,
    expectedSizeBytes: UInt64,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> URL {
    try Task.checkCancellation()
    let session = URLSession(
      configuration: configuration,
      delegate: self,
      delegateQueue: nil
    )
    defer { session.finishTasksAndInvalidate() }

    let task = session.downloadTask(with: sourceURL)
    let key = ObjectIdentifier(task)

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        transfers[key] = Transfer(
          continuation: continuation,
          expectedSizeBytes: expectedSizeBytes,
          onBytes: onBytes
        )
        lock.unlock()
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    let key = ObjectIdentifier(downloadTask)
    let received = UInt64(max(0, totalBytesWritten))
    var exceededPinnedSize = false
    var pendingReport: ArtifactByteProgressHandler?

    lock.lock()
    if var transfer = transfers[key] {
      if received > transfer.expectedSizeBytes {
        transfer.failure = ArtifactStageError.sizeMismatch(
          expected: transfer.expectedSizeBytes,
          actual: received
        )
        transfers[key] = transfer
        exceededPinnedSize = true
      } else {
        let now = Date()
        let elapsed =
          transfer.lastReportedAt.map { now.timeIntervalSince($0) }
          ?? Self.reportIntervalSeconds
        let delta =
          received >= transfer.lastReportedBytes
          ? received - transfer.lastReportedBytes : 0
        if elapsed >= Self.reportIntervalSeconds
          || delta >= Self.reportByteInterval
        {
          transfer.lastReportedAt = now
          transfer.lastReportedBytes = received
          transfers[key] = transfer
          pendingReport = transfer.onBytes
        }
      }
    }
    lock.unlock()

    guard !exceededPinnedSize else {
      downloadTask.cancel()
      return
    }
    pendingReport?(received)
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    let key = ObjectIdentifier(downloadTask)
    let fileManager = FileManager.default
    let temporaryURL = fileManager.temporaryDirectory.appendingPathComponent(
      "omarchy-artifact-download-\(UUID().uuidString.lowercased())",
      isDirectory: false
    )

    var moveFailure: (any Error)?
    do {
      try fileManager.moveItem(at: location, to: temporaryURL)
    } catch {
      moveFailure = error
    }

    guard let response = downloadTask.response as? HTTPURLResponse,
      (200...299).contains(response.statusCode)
    else {
      try? fileManager.removeItem(at: temporaryURL)
      let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
      finish(key, with: .failure(ArtifactStageError.unexpectedHTTPStatus(status)))
      return
    }
    if let moveFailure {
      finish(key, with: .failure(moveFailure))
      return
    }
    finish(key, with: .success(temporaryURL))
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    let key = ObjectIdentifier(task)
    lock.lock()
    let recordedFailure = transfers[key]?.failure
    lock.unlock()

    if let recordedFailure {
      finish(key, with: .failure(recordedFailure))
    } else if let error {
      let cancelled = (error as? URLError)?.code == .cancelled || Task.isCancelled
      finish(
        key,
        with: .failure(cancelled ? CancellationError() : error)
      )
    } else {
      finish(key, with: .failure(URLError(.badServerResponse)))
    }
  }

  private func finish(
    _ key: ObjectIdentifier,
    with result: Result<URL, any Error>
  ) {
    lock.lock()
    let transfer = transfers.removeValue(forKey: key)
    lock.unlock()

    guard let transfer else {
      if case .success(let fileURL) = result {
        try? FileManager.default.removeItem(at: fileURL)
      }
      return
    }
    transfer.continuation.resume(with: result)
  }
}

/// Downloads an artifact as parallel HTTP byte ranges written in place, each
/// over its own session, so one slow or dropped connection neither stalls nor
/// restarts the whole file. A dropped range resumes from its last byte. A
/// server that ignores Range falls back to the single-stream downloader. The
/// stager still checks the size and SHA-256 of the result.
final class RangedArtifactDownloader: NSObject, ArtifactDownloading, URLSessionDataDelegate,
  @unchecked Sendable
{
  struct Tuning: Sendable {
    var rangeBytes: UInt64 = 64 * 1_048_576
    var connections = 4
    var attemptsWithoutProgress = 8
    var retryDelay: Duration = .seconds(1)
    var maxRetryDelay: Duration = .seconds(30)

    /// Doubles from `retryDelay` up to `maxRetryDelay`, so the defaults ride
    /// out about a minute and a half of lost network (sleep, Wi-Fi roaming)
    /// before the partial file is given up.
    func delay(afterFailures failures: Int) -> Duration {
      var delay = retryDelay
      for _ in 1..<max(1, failures) where delay < maxRetryDelay {
        delay *= 2
      }
      return min(delay, maxRetryDelay)
    }
  }

  private enum RangeFailure: Error {
    case ignored
  }

  private struct Attempt {
    let written: UInt64
    let failure: (any Error)?
  }

  private struct Transfer {
    let continuation: CheckedContinuation<Attempt, Never>
    let job: Job
    let range: ClosedRange<UInt64>
    var written: UInt64 = 0
    var failure: (any Error)?
  }

  private let configuration: URLSessionConfiguration
  private let tuning: Tuning
  private let fallback: any ArtifactDownloading
  private let lock = NSLock()
  private var transfers = [ObjectIdentifier: Transfer]()

  init(
    configuration: URLSessionConfiguration = .ephemeral,
    tuning: Tuning = Tuning(),
    fallback: (any ArtifactDownloading)? = nil
  ) {
    self.configuration = configuration
    self.tuning = tuning
    self.fallback =
      fallback ?? ProgressReportingArtifactDownloader(configuration: configuration)
    super.init()
  }

  func download(from sourceURL: URL) async throws -> URL {
    try await fallback.download(from: sourceURL)
  }

  func download(
    from sourceURL: URL,
    expectedSizeBytes: UInt64,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> URL {
    guard expectedSizeBytes > 0, expectedSizeBytes != UInt64.max else {
      return try await fallback.download(
        from: sourceURL, expectedSizeBytes: expectedSizeBytes, onBytes: onBytes)
    }
    do {
      return try await downloadRanges(
        from: sourceURL, expectedSizeBytes: expectedSizeBytes, onBytes: onBytes)
    } catch RangeFailure.ignored {
      // The ranged file is already closed and removed, so the fallback does
      // not hold a second copy of the payload on disk.
      return try await fallback.download(
        from: sourceURL, expectedSizeBytes: expectedSizeBytes, onBytes: onBytes)
    }
  }

  private func downloadRanges(
    from sourceURL: URL,
    expectedSizeBytes: UInt64,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> URL {
    try Task.checkCancellation()

    let output = FileManager.default.temporaryDirectory.appendingPathComponent(
      "omarchy-artifact-download-\(UUID().uuidString.lowercased())",
      isDirectory: false
    )
    let descriptor = Darwin.open(output.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
    }
    var keepOutput = false
    defer {
      Darwin.close(descriptor)
      if !keepOutput {
        try? FileManager.default.removeItem(at: output)
      }
    }
    guard Darwin.ftruncate(descriptor, off_t(expectedSizeBytes)) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
    }

    let job = Job(
      descriptor: descriptor,
      sizeBytes: expectedSizeBytes,
      rangeBytes: max(1, tuning.rangeBytes),
      onBytes: onBytes
    )
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<min(max(1, tuning.connections), job.rangeCount) {
        group.addTask { try await self.work(job, url: sourceURL) }
      }
      // Unlike waitForAll(), rethrowing from next() leaves the group body,
      // which cancels the other connections instead of letting them fetch
      // the rest of the file first.
      while try await group.next() != nil {}
    }
    keepOutput = true
    return output
  }

  private func work(_ job: Job, url: URL) async throws {
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    while let range = job.claim() {
      var start = range.lowerBound
      var failuresWithoutProgress = 0
      while start <= range.upperBound {
        try Task.checkCancellation()
        let attempt = await fetch(start...range.upperBound, of: url, for: job, in: session)
        start += attempt.written
        guard let failure = attempt.failure else {
          continue
        }
        guard PayloadPrefetchFailure.isTransient(failure) else {
          throw failure
        }
        failuresWithoutProgress = attempt.written > 0 ? 1 : failuresWithoutProgress + 1
        guard failuresWithoutProgress < tuning.attemptsWithoutProgress else {
          throw failure
        }
        try await Task.sleep(for: tuning.delay(afterFailures: failuresWithoutProgress))
      }
    }
  }

  private func fetch(
    _ range: ClosedRange<UInt64>,
    of url: URL,
    for job: Job,
    in session: URLSession
  ) async -> Attempt {
    var request = URLRequest(url: url)
    request.setValue(
      "bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
    // Range offsets count stored bytes; a content-coded body would not match.
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    let task = session.dataTask(with: request)
    let key = ObjectIdentifier(task)

    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        lock.withLock {
          transfers[key] = Transfer(continuation: continuation, job: job, range: range)
        }
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    let key = ObjectIdentifier(dataTask)
    let failure: (any Error)? = lock.withLock {
      guard var transfer = transfers[key] else {
        return nil
      }
      transfer.failure = Self.rangeFailure(
        response, range: transfer.range, sizeBytes: transfer.job.sizeBytes)
      transfers[key] = transfer
      return transfer.failure
    }
    completionHandler(failure == nil ? .allow : .cancel)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    let key = ObjectIdentifier(dataTask)
    guard let transfer = lock.withLock({ transfers[key] }), transfer.failure == nil else {
      return
    }
    let length = UInt64(transfer.range.count)
    let incoming = UInt64(data.count)
    guard transfer.written + incoming <= length else {
      record(
        ArtifactStageError.sizeMismatch(expected: length, actual: transfer.written + incoming),
        for: key)
      dataTask.cancel()
      return
    }
    let offset = transfer.range.lowerBound + transfer.written
    if let failure = transfer.job.write(data, at: offset) {
      record(failure, for: key)
      dataTask.cancel()
      return
    }
    lock.withLock { transfers[key]?.written += incoming }
    transfer.job.received(incoming)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    let key = ObjectIdentifier(task)
    guard let transfer = lock.withLock({ transfers.removeValue(forKey: key) }) else {
      return
    }
    let failure: (any Error)?
    if let recorded = transfer.failure {
      failure = recorded
    } else if let error {
      failure = (error as? URLError)?.code == .cancelled ? CancellationError() : error
    } else if transfer.written != UInt64(transfer.range.count) {
      failure = URLError(.networkConnectionLost)
    } else {
      failure = nil
    }
    transfer.continuation.resume(returning: Attempt(written: transfer.written, failure: failure))
  }

  private func record(_ failure: any Error, for key: ObjectIdentifier) {
    lock.withLock { transfers[key]?.failure = failure }
  }

  /// Accepts only a 206 for exactly the requested bytes of an object of the
  /// pinned size. A 200 means the server ignored Range.
  private static func rangeFailure(
    _ response: URLResponse,
    range: ClosedRange<UInt64>,
    sizeBytes: UInt64
  ) -> (any Error)? {
    guard let http = response as? HTTPURLResponse else {
      return ArtifactStageError.unexpectedHTTPStatus(0)
    }
    if http.statusCode == 200 {
      return RangeFailure.ignored
    }
    guard http.statusCode == 206 else {
      return ArtifactStageError.unexpectedHTTPStatus(http.statusCode)
    }
    if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"),
      !encoding.isEmpty, encoding.lowercased() != "identity"
    {
      return RangeFailure.ignored
    }
    // Content-Range: bytes <first>-<last>/<total>
    let fields = (http.value(forHTTPHeaderField: "Content-Range") ?? "")
      .split(whereSeparator: { " -/".contains($0) })
    guard fields.count == 4, fields[0] == "bytes",
      let first = UInt64(fields[1]), let last = UInt64(fields[2]),
      let total = UInt64(fields[3])
    else {
      return RangeFailure.ignored
    }
    guard total == sizeBytes else {
      return ArtifactStageError.sizeMismatch(expected: sizeBytes, actual: total)
    }
    return first == range.lowerBound && last == range.upperBound ? nil : RangeFailure.ignored
  }

  /// One download: hands out ranges, writes bytes in place, and meters progress.
  private final class Job: @unchecked Sendable {
    private static let reportIntervalSeconds: TimeInterval = 0.25

    let sizeBytes: UInt64
    let rangeCount: Int
    private let descriptor: Int32
    private let rangeBytes: UInt64
    private let onBytes: ArtifactByteProgressHandler?
    private let lock = NSLock()
    private var nextRange = 0
    private var receivedBytes: UInt64 = 0
    private var lastReportedAt: Date?
    private let deliveryLock = NSLock()
    private var deliveredBytes: UInt64 = 0

    init(
      descriptor: Int32,
      sizeBytes: UInt64,
      rangeBytes: UInt64,
      onBytes: ArtifactByteProgressHandler?
    ) {
      self.descriptor = descriptor
      self.sizeBytes = sizeBytes
      self.rangeBytes = rangeBytes
      self.onBytes = onBytes
      rangeCount = Int((sizeBytes + rangeBytes - 1) / rangeBytes)
    }

    func claim() -> ClosedRange<UInt64>? {
      lock.withLock {
        guard nextRange < rangeCount else {
          return nil
        }
        let first = UInt64(nextRange) * rangeBytes
        nextRange += 1
        return first...(min(first + rangeBytes, sizeBytes) - 1)
      }
    }

    func write(_ data: Data, at offset: UInt64) -> (any Error)? {
      data.withUnsafeBytes { buffer -> (any Error)? in
        var done = 0
        while done < buffer.count {
          let count = Darwin.pwrite(
            descriptor, buffer.baseAddress! + done, buffer.count - done,
            off_t(offset) + off_t(done))
          guard count > 0 else {
            if count < 0, Darwin.errno == EINTR {
              continue
            }
            return POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
          }
          done += count
        }
        return nil
      }
    }

    func received(_ count: UInt64) {
      guard let onBytes else {
        return
      }
      let report: UInt64? = lock.withLock {
        receivedBytes += count
        let now = Date()
        let due =
          receivedBytes == sizeBytes
          || lastReportedAt.map { now.timeIntervalSince($0) >= Self.reportIntervalSeconds }
            ?? true
        guard due else {
          return nil
        }
        lastReportedAt = now
        return receivedBytes
      }
      guard let report else {
        return
      }
      // Connections report from different queues; deliver in order so a
      // late, smaller total never follows a larger one.
      deliveryLock.withLock {
        guard report > deliveredBytes else {
          return
        }
        deliveredBytes = report
        onBytes(report)
      }
    }
  }
}
