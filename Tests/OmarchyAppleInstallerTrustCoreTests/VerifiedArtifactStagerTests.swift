import CryptoKit
import Darwin
import Foundation
import Network
import XCTest

@testable import OmarchyAppleInstallerTrustCore

final class VerifiedArtifactStagerTests: XCTestCase {
  func testCancellationAtAssemblyDoesNotPromoteAndKeepsVerifiedParts() async throws {
    let data = Data(repeating: 42, count: 16_384)
    let fixture = try partsFixture(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let operation = Task {
      try await VerifiedArtifactStager(
        downloader: RoutedFixtureDownloader(responses: fixture.responses)
      )
      .stage(fixture.artifact, in: directory) { progress in
        if progress.phase == .assembling {
          withUnsafeCurrentTask { $0?.cancel() }
        }
      }
    }
    do {
      _ = try await operation.value
      XCTFail("Cancelled assembly must not promote a payload")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(fixture.artifact.fileName).path))
    let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(Set(remaining), Set(fixture.artifact.parts.map(\.fileName)))
  }

  func testDescriptorRejectsUntrustedInputs() {
    XCTAssertThrowsError(
      try descriptor(source: "http://example.com/installer.tar.gz")
    ) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidSourceURL)
    }
    XCTAssertThrowsError(try descriptor(fileName: "../installer.tar.gz")) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidFileName)
    }
    XCTAssertThrowsError(try descriptor(fileName: "installer\0ignored.tar.gz")) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidFileName)
    }
    XCTAssertThrowsError(try descriptor(digest: "sha256:ABC")) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidDigest)
    }
  }

  func testValidDownloadIsVerifiedAndAcceptedAtomically() async throws {
    let data = Data("pinned installer payload".utf8)
    let downloader = FixtureArtifactDownloader(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = try descriptor(data: data)

    let result = try await VerifiedArtifactStager(
      downloader: downloader
    ).stage(artifact, in: directory)

    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
    XCTAssertFalse(result.reusedExistingFile)
    XCTAssertEqual(result.materialization, .atomicRename)
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 1)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      [artifact.fileName]
    )
  }

  func testBundledEngineIsVerifiedWithoutDownloadAndRemainsInBundle() async throws {
    let data = Data("bundled engine".utf8)
    let artifact = try descriptor(data: data)
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("bundle")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let source = bundle.appendingPathComponent(artifact.fileName)
    try data.write(to: source)
    let downloader = FixtureArtifactDownloader(data: Data("must not download".utf8))
    let result = try await VerifiedArtifactStager(
      downloader: downloader, bundledEngineDirectory: bundle
    ).stage(artifact, in: root.appendingPathComponent("staging"))
    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
    XCTAssertEqual(try Data(contentsOf: source), data)
    let count = await downloader.downloadCount
    XCTAssertEqual(count, 0)
    try Data("tampered bytes".utf8).write(to: source)
    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader, bundledEngineDirectory: bundle)
        .stage(artifact, in: root.appendingPathComponent("other-staging"))
    ) { error in
      guard case .digestMismatch = error as? ArtifactStageError else {
        return XCTFail("Expected digest mismatch, got \(error)")
      }
    }
  }

  func testPayloadStillDownloadsWhenSameNamedFileIsBundled() async throws {
    let data = Data("OS payload".utf8)
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let artifact = try PinnedInstallerArtifact(
      role: "payload", sourceURL: URL(string: "https://example.com/os.zip")!,
      fileName: "os.zip", expectedDigest: digest(data), expectedSizeBytes: UInt64(data.count)
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try data.write(to: root.appendingPathComponent("os.zip"))
    let downloader = FixtureArtifactDownloader(data: data)
    let result = try await VerifiedArtifactStager(
      downloader: downloader, bundledEngineDirectory: root
    ).stage(artifact, in: root.appendingPathComponent("staging"))
    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
    let count = await downloader.downloadCount
    XCTAssertEqual(count, 1)
  }

  func testExactExistingArtifactIsReusedWithoutDownload() async throws {
    let data = Data("pinned installer payload".utf8)
    let downloader = FixtureArtifactDownloader(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = try descriptor(data: data)
    let stager = VerifiedArtifactStager(downloader: downloader)

    _ = try await stager.stage(artifact, in: directory)
    let replay = try await stager.stage(artifact, in: directory)

    XCTAssertTrue(replay.reusedExistingFile)
    XCTAssertEqual(replay.materialization, .reusedExistingFile)
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 1)
  }

  func testOfflineBundleStagesEveryRoleWithoutDownload() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Artifacts")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let downloader = FixtureArtifactDownloader(data: Data("must not download".utf8))
    let stager = VerifiedArtifactStager(
      downloader: downloader, bundledArtifactDirectory: bundle, requiresBundledArtifacts: true)
    for role in ["engine", "metadata", "payload"] {
      let data = Data("bundled \(role)".utf8)
      let artifact = try PinnedInstallerArtifact(
        role: role, sourceURL: URL(string: "https://example.invalid/\(role)")!,
        fileName: role, expectedDigest: digest(data), expectedSizeBytes: UInt64(data.count))
      try data.write(to: bundle.appendingPathComponent(role))
      let result = try await stager.stage(artifact, in: root.appendingPathComponent("staging"))
      XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
      XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent(role)), data)
    }
    let count = await downloader.downloadCount
    XCTAssertEqual(count, 0)
  }

  func testOfflineBundleFailsClosedWithoutNetworkFallback() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Artifacts")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let downloader = FixtureArtifactDownloader(data: Data("must not download".utf8))
    let stager = VerifiedArtifactStager(
      downloader: downloader, bundledArtifactDirectory: bundle, requiresBundledArtifacts: true)
    let data = Data("expected payload".utf8)
    let artifact = try PinnedInstallerArtifact(
      role: "payload", sourceURL: URL(string: "https://example.invalid/os.zip")!,
      fileName: "os.zip", expectedDigest: digest(data), expectedSizeBytes: UInt64(data.count))
    await assertThrows(try await stager.stage(artifact, in: root.appendingPathComponent("missing")))
    {
      XCTAssertEqual($0 as? ArtifactStageError, .bundledArtifactMissing("os.zip"))
    }
    try Data(repeating: 0, count: data.count).write(to: bundle.appendingPathComponent("os.zip"))
    await assertThrows(try await stager.stage(artifact, in: root.appendingPathComponent("corrupt")))
    {
      guard case .digestMismatch = $0 as? ArtifactStageError else {
        return XCTFail("Expected digest mismatch, got \($0)")
      }
    }
    let count = await downloader.downloadCount
    XCTAssertEqual(count, 0)
  }

  func testDigestMismatchLeavesNoAcceptedOrPendingFile() async throws {
    let expected = Data("expected".utf8)
    let delivered = Data("tampered".utf8)
    let downloader = FixtureArtifactDownloader(data: delivered)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = try descriptor(data: expected)

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        artifact,
        in: directory
      )
    ) { error in
      guard case .digestMismatch = error as? ArtifactStageError else {
        return XCTFail("Expected digestMismatch, got \(error)")
      }
    }

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      []
    )
  }

  func testWrongExistingDestinationFailsClosed() async throws {
    let data = Data("expected".utf8)
    let downloader = FixtureArtifactDownloader(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let artifact = try descriptor(data: data)
    try Data("wrong".utf8).write(
      to: directory.appendingPathComponent(artifact.fileName)
    )

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        artifact,
        in: directory
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .destinationConflict(artifact.fileName)
      )
    }
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 0)
  }

  func testSizeMismatchIsRejectedBeforeAcceptance() async throws {
    let data = Data("payload".utf8)
    let downloader = FixtureArtifactDownloader(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = try PinnedInstallerArtifact(
      role: "engine",
      sourceURL: URL(string: "https://example.com/installer.tar.gz")!,
      fileName: "installer.tar.gz",
      expectedDigest: digest(data),
      expectedSizeBytes: UInt64(data.count + 1)
    )

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        artifact,
        in: directory
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .sizeMismatch(
          expected: UInt64(data.count + 1),
          actual: UInt64(data.count)
        )
      )
    }
  }

  func testCrossDeviceRenameUsesVerifiedCopyFallback() async throws {
    let data = Data("cross-device payload".utf8)
    let downloader = FixtureArtifactDownloader(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = try descriptor(data: data)
    let promoter = AtomicArtifactFilePromoter { _, _ in .failure(EXDEV) }

    let result = try await VerifiedArtifactStager(
      downloader: downloader,
      promoter: promoter
    ).stage(artifact, in: directory)

    XCTAssertEqual(result.materialization, .verifiedCopyFallback)
    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
  }

  func testRenameFailureOtherThanCrossDeviceDoesNotCopy() async throws {
    let data = Data("do not copy".utf8)
    let source = temporaryDirectory()
    let destination = temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: source)
      try? FileManager.default.removeItem(at: destination)
    }
    try data.write(to: source, options: .withoutOverwriting)
    let promoter = AtomicArtifactFilePromoter { _, _ in .failure(EACCES) }

    XCTAssertThrowsError(try promoter.promote(source: source, pending: destination))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testMultiPartDescriptorRejectsUnusableManifests() throws {
    let data = Data("multi-part installer payload".utf8)
    let chunks = partition(data, into: 2)

    XCTAssertThrowsError(
      try descriptor(data: data, parts: [try part(chunks[0], index: 0)])
    ) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidPartCount(1))
    }
    XCTAssertThrowsError(
      try descriptor(
        data: Data(repeating: 0x61, count: 17),
        parts: try (0..<17).map { index in
          try part(Data([0x61]), index: index)
        }
      )
    ) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidPartCount(17))
    }
    XCTAssertThrowsError(
      try descriptor(
        data: data,
        parts: [
          try part(chunks[0], index: 0),
          try part(chunks[1], index: 0),
        ]
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .invalidPartFileName("installer.tar.gz.part00")
      )
    }
    XCTAssertThrowsError(
      try descriptor(
        data: data,
        parts: [
          try part(chunks[0], fileName: "installer.tar.gz"),
          try part(chunks[1], index: 1),
        ]
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .invalidPartFileName("installer.tar.gz")
      )
    }
    XCTAssertThrowsError(
      try part(chunks[0], fileName: "../installer.tar.gz.part00")
    ) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidFileName)
    }
    XCTAssertThrowsError(
      try part(chunks[0], source: "http://example.com/part00")
    ) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidSourceURL)
    }
    XCTAssertThrowsError(
      try descriptor(
        data: data,
        parts: [
          try part(chunks[0], index: 0),
          try part(chunks[1].dropLast(), index: 1),
        ]
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .partSizeSumMismatch(
          expected: UInt64(data.count),
          actual: UInt64(data.count - 1)
        )
      )
    }
  }

  func testMultiPartDescriptorAcceptsBoundaryPartCounts() throws {
    let data = Data("multi-part installer payload".utf8)
    let pair = partition(data, into: 2)
    let twoParts = try descriptor(
      data: data,
      parts: [try part(pair[0], index: 0), try part(pair[1], index: 1)]
    )
    XCTAssertEqual(twoParts.parts.count, 2)

    let wide = Data(repeating: 0x62, count: 16)
    let chunks = partition(wide, into: 16)
    let sixteenParts = try descriptor(
      data: wide,
      parts: try chunks.enumerated().map { index, chunk in
        try part(chunk, index: index)
      }
    )
    XCTAssertEqual(sixteenParts.parts.count, 16)
  }

  func testMultiPartPayloadIsAssembledFromVerifiedParts() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let fixture = try partsFixture(data: data)
    let downloader = RoutedFixtureDownloader(responses: fixture.responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = ProgressRecorder()

    let result = try await VerifiedArtifactStager(downloader: downloader).stage(
      fixture.artifact,
      in: directory,
      progress: recorder.handler
    )

    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
    XCTAssertEqual(result.materialization, .assembledFromParts)
    XCTAssertFalse(result.reusedExistingFile)
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 2)
    let requestedURLs = await downloader.requestedURLs
    XCTAssertEqual(requestedURLs, fixture.artifact.parts.map(\.sourceURL))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      [fixture.artifact.fileName]
    )

    let events = recorder.events
    XCTAssertEqual(
      events.map(\.bytesCompleted),
      events.map(\.bytesCompleted).sorted()
    )
    XCTAssertTrue(events.contains { $0.phase == .assembling })
    XCTAssertTrue(
      events.allSatisfy { $0.role == "engine" && $0.totalBytes == UInt64(data.count) }
    )
    XCTAssertEqual(events.last?.phase, .verified)
    XCTAssertEqual(events.last?.bytesCompleted, UInt64(data.count))
    XCTAssertEqual(
      events.compactMap(\.partCount).allSatisfy { $0 == 2 },
      true
    )
  }

  func testPartDigestMismatchKeepsEarlierVerifiedPart() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let fixture = try partsFixture(data: data)
    var responses = fixture.responses
    let tampered = fixture.artifact.parts[1]
    responses[tampered.sourceURL] = Data(
      repeating: 0x21,
      count: Int(tampered.expectedSizeBytes)
    )
    let downloader = RoutedFixtureDownloader(responses: responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        fixture.artifact,
        in: directory
      )
    ) { error in
      guard case .digestMismatch = error as? ArtifactStageError else {
        return XCTFail("Expected digestMismatch, got \(error)")
      }
    }

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      [fixture.artifact.parts[0].fileName]
    )
  }

  func testWholeDigestMismatchKeepsVerifiedParts() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let decoy = Data(repeating: 0x7a, count: data.count)
    let fixture = try partsFixture(data: data, wholeDigest: digest(decoy))
    let downloader = RoutedFixtureDownloader(responses: fixture.responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        fixture.artifact,
        in: directory
      )
    ) { error in
      guard case .digestMismatch = error as? ArtifactStageError else {
        return XCTFail("Expected digestMismatch, got \(error)")
      }
    }

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
      fixture.artifact.parts.map(\.fileName).sorted()
    )
  }

  func testAssembledPayloadIsReusedWithoutRedownloadingParts() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let fixture = try partsFixture(data: data)
    let downloader = RoutedFixtureDownloader(responses: fixture.responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stager = VerifiedArtifactStager(downloader: downloader)

    _ = try await stager.stage(fixture.artifact, in: directory)
    try Data("stale part".utf8).write(
      to: directory.appendingPathComponent(
        fixture.artifact.parts[0].fileName
      )
    )
    let replay = try await stager.stage(fixture.artifact, in: directory)

    XCTAssertTrue(replay.reusedExistingFile)
    XCTAssertEqual(replay.materialization, .reusedExistingFile)
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 2)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      [fixture.artifact.fileName]
    )
  }

  func testExistingVerifiedPartIsNotDownloadedAgain() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let fixture = try partsFixture(data: data)
    let downloader = RoutedFixtureDownloader(responses: fixture.responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try fixture.chunks[0].write(
      to: directory.appendingPathComponent(
        fixture.artifact.parts[0].fileName
      )
    )

    let result = try await VerifiedArtifactStager(downloader: downloader).stage(
      fixture.artifact,
      in: directory
    )

    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 1)
    let requestedURLs = await downloader.requestedURLs
    XCTAssertEqual(requestedURLs, [fixture.artifact.parts[1].sourceURL])
  }

  func testConflictingExistingPartFailsClosedBeforeDownload() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let fixture = try partsFixture(data: data)
    let downloader = RoutedFixtureDownloader(responses: fixture.responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try Data(repeating: 0x33, count: Int(fixture.artifact.parts[0].expectedSizeBytes))
      .write(
        to: directory.appendingPathComponent(
          fixture.artifact.parts[0].fileName
        )
      )

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        fixture.artifact,
        in: directory
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .destinationConflict(fixture.artifact.parts[0].fileName)
      )
    }
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 0)
  }

  func testOversizedDeliveryIsRejectedAndStagesNothing() async throws {
    let data = Data("pinned installer payload".utf8)
    let artifact = try descriptor(data: data)
    let downloader = RoutedFixtureDownloader(responses: [
      artifact.sourceURL: data + Data("overfeed".utf8)
    ])
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        artifact,
        in: directory
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .sizeMismatch(
          expected: UInt64(data.count),
          actual: UInt64(data.count + 8)
        )
      )
    }

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      []
    )
  }

  func testSingleFileStagingReportsDownloadThenVerifiedProgress() async throws {
    let data = Data("pinned installer payload".utf8)
    let artifact = try descriptor(data: data)
    let downloader = RoutedFixtureDownloader(responses: [
      artifact.sourceURL: data
    ])
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = ProgressRecorder()

    _ = try await VerifiedArtifactStager(downloader: downloader).stage(
      artifact,
      in: directory,
      progress: recorder.handler
    )

    let events = recorder.events
    XCTAssertEqual(events.first?.phase, .downloading)
    XCTAssertEqual(events.last?.phase, .verified)
    XCTAssertEqual(events.last?.bytesCompleted, UInt64(data.count))
    XCTAssertEqual(events.last?.totalBytes, UInt64(data.count))
    XCTAssertTrue(events.allSatisfy { $0.partIndex == nil && $0.partCount == nil })
    XCTAssertEqual(
      events.map(\.bytesCompleted),
      events.map(\.bytesCompleted).sorted()
    )
  }

  func testRequiredFreeBytesIsTwiceThePayloadSize() {
    XCTAssertEqual(VerifiedArtifactStager.requiredFreeBytes(forPayloadSize: 100), 200)
    XCTAssertEqual(
      VerifiedArtifactStager.requiredFreeBytes(forPayloadSize: UInt64.max), UInt64.max)
  }

  func testRequiredFreeBytesOnResumeCountsVerifiedPartsAlreadyOnDisk() {
    XCTAssertEqual(
      VerifiedArtifactStager.requiredFreeBytes(forPayloadSize: 100, alreadyOnDisk: 80),
      120)
    XCTAssertEqual(
      VerifiedArtifactStager.requiredFreeBytes(forPayloadSize: 100, alreadyOnDisk: 200),
      0)
    XCTAssertEqual(
      VerifiedArtifactStager.requiredFreeBytes(forPayloadSize: 100, alreadyOnDisk: 0),
      200)
  }

  func testMatchesHashesTheOnDiskFile() throws {
    let data = Data("pinned installer payload".utf8)
    let artifact = try descriptor(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(artifact.fileName)
    try data.write(to: file)
    XCTAssertTrue(VerifiedArtifactStager().matches(artifact, at: file))
    try Data(repeating: 0x61, count: data.count).write(to: file)
    XCTAssertFalse(VerifiedArtifactStager().matches(artifact, at: file))
  }

  func testDownloadTaskCancelsWhenTheSwiftTaskIsCancelled() async throws {
    let server = try SlowHTTPServer()
    let url = try await server.start()
    defer { server.stop() }
    let downloader = ProgressReportingArtifactDownloader()
    let download = Task {
      try await downloader.download(
        from: url, expectedSizeBytes: 50_000_000, onBytes: nil)
    }
    try await Task.sleep(for: .milliseconds(250))
    download.cancel()
    do {
      _ = try await download.value
      XCTFail("cancelled download must not succeed")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testRangedDownloadResumesADroppedRangeFromItsLastByte() async throws {
    let payload = rangeFixture(count: 300_000)
    let server = try RangeHTTPServer(payload: payload, drops: 1)
    let url = try await server.start()
    defer { server.stop() }
    let downloader = RangedArtifactDownloader(
      tuning: .init(rangeBytes: 1_000_000, connections: 1, retryDelay: .zero))

    let file = try await downloader.download(
      from: url, expectedSizeBytes: UInt64(payload.count), onBytes: nil)
    defer { try? FileManager.default.removeItem(at: file) }

    XCTAssertEqual(try Data(contentsOf: file), payload)
    XCTAssertEqual(server.rangeHeaders, ["bytes=0-299999", "bytes=150000-299999"])
  }

  func testRangesRunInParallelOverSeparateConnectionsAndProgressReachesTheTotal() async throws {
    let payload = rangeFixture(count: 1_048_576)
    let server = try RangeHTTPServer(payload: payload, responseDelay: .milliseconds(50))
    let url = try await server.start()
    defer { server.stop() }
    let downloader = RangedArtifactDownloader(
      tuning: .init(rangeBytes: 65_536, connections: 4, retryDelay: .zero))
    let reported = ByteRecorder()

    let file = try await downloader.download(
      from: url, expectedSizeBytes: UInt64(payload.count), onBytes: reported.handler)
    defer { try? FileManager.default.removeItem(at: file) }

    XCTAssertEqual(try Data(contentsOf: file), payload)
    let expected = (0..<16).map { "bytes=\($0 * 65_536)-\($0 * 65_536 + 65_535)" }
    XCTAssertEqual(Set(server.rangeHeaders.compactMap { $0 }), Set(expected))
    XCTAssertEqual(server.rangeHeaders.count, 16)
    XCTAssertGreaterThanOrEqual(server.peakActiveRequests, 2)
    XCTAssertGreaterThanOrEqual(server.connectionCount, 2)
    XCTAssertEqual(reported.values.last, UInt64(payload.count))
    XCTAssertEqual(reported.values, reported.values.sorted())
    XCTAssertEqual(Set(server.acceptEncodings), ["identity"])
  }

  func testAFailedRangeStopsTheOtherConnections() async throws {
    let payload = rangeFixture(count: 1_048_576)
    let server = try RangeHTTPServer(
      payload: payload, failFirstWith: 404, responseDelay: .milliseconds(50))
    let url = try await server.start()
    defer { server.stop() }
    let downloader = RangedArtifactDownloader(
      tuning: .init(rangeBytes: 65_536, connections: 4, retryDelay: .zero))

    do {
      let file = try await downloader.download(
        from: url, expectedSizeBytes: UInt64(payload.count), onBytes: nil)
      try? FileManager.default.removeItem(at: file)
      XCTFail("a 404 range must fail the download")
    } catch {
      XCTAssertEqual(error as? ArtifactStageError, .unexpectedHTTPStatus(404))
    }
    // Without cancellation the other three connections fetch all 16 ranges.
    XCTAssertLessThan(server.rangeHeaders.count, 16)
  }

  func testRetryDelayDoublesUpToTheCap() {
    let tuning = RangedArtifactDownloader.Tuning()
    XCTAssertEqual(
      (1...7).map { tuning.delay(afterFailures: $0) },
      [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
    XCTAssertEqual(
      RangedArtifactDownloader.Tuning(retryDelay: .zero).delay(afterFailures: 5), .zero)
  }

  func testServerThatIgnoresRangeFallsBackToOneStream() async throws {
    let payload = rangeFixture(count: 200_000)
    let server = try RangeHTTPServer(payload: payload, honorsRange: false)
    let url = try await server.start()
    defer { server.stop() }
    let downloader = RangedArtifactDownloader(
      tuning: .init(rangeBytes: 65_536, connections: 2, retryDelay: .zero))

    let file = try await downloader.download(
      from: url, expectedSizeBytes: UInt64(payload.count), onBytes: nil)
    defer { try? FileManager.default.removeItem(at: file) }

    XCTAssertEqual(try Data(contentsOf: file), payload)
    XCTAssertTrue(server.rangeHeaders.contains(nil), "the fallback asks for the whole file")
  }

  private func rangeFixture(count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
  }

  private func descriptor(
    source: String = "https://example.com/installer.tar.gz",
    fileName: String = "installer.tar.gz",
    digest: String? = nil,
    data: Data = Data("pinned installer payload".utf8),
    parts: [PinnedArtifactPart] = []
  ) throws -> PinnedInstallerArtifact {
    try PinnedInstallerArtifact(
      role: "engine",
      sourceURL: URL(string: source)!,
      fileName: fileName,
      expectedDigest: digest ?? self.digest(data),
      expectedSizeBytes: UInt64(data.count),
      parts: parts
    )
  }

  private func part(
    _ data: Data,
    index: Int = 0,
    fileName: String? = nil,
    source: String? = nil,
    digest: String? = nil
  ) throws -> PinnedArtifactPart {
    let name = fileName ?? String(format: "installer.tar.gz.part%02d", index)
    return try PinnedArtifactPart(
      sourceURL: URL(string: source ?? "https://example.com/\(name)")!,
      fileName: name,
      expectedDigest: digest ?? self.digest(data),
      expectedSizeBytes: UInt64(data.count)
    )
  }

  private func partsFixture(
    data: Data,
    count: Int = 2,
    fileName: String = "installer.tar.gz",
    wholeDigest: String? = nil
  ) throws -> (
    artifact: PinnedInstallerArtifact, chunks: [Data], responses: [URL: Data]
  ) {
    let chunks = partition(data, into: count)
    var parts = [PinnedArtifactPart]()
    var responses = [URL: Data]()
    for (index, chunk) in chunks.enumerated() {
      let part = try self.part(chunk, index: index)
      parts.append(part)
      responses[part.sourceURL] = chunk
    }
    let artifact = try descriptor(
      fileName: fileName,
      digest: wholeDigest ?? digest(data),
      data: data,
      parts: parts
    )
    return (artifact, chunks, responses)
  }

  private func partition(_ data: Data, into count: Int) -> [Data] {
    let chunkSize = data.count / count
    var chunks = [Data]()
    var offset = 0
    for index in 0..<count {
      let length = index == count - 1 ? data.count - offset : chunkSize
      chunks.append(data.subdata(in: offset..<(offset + length)))
      offset += length
    }
    return chunks
  }

  private func digest(_ data: Data) -> String {
    "sha256:"
      + SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "omarchy-artifact-stager-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
  }
}

private actor FixtureArtifactDownloader: ArtifactDownloading {
  private let data: Data
  private(set) var downloadCount = 0

  init(data: Data) {
    self.data = data
  }

  func download(from sourceURL: URL) async throws -> URL {
    downloadCount += 1
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "omarchy-downloader-\(UUID().uuidString.lowercased())"
    )
    try data.write(to: fileURL, options: .withoutOverwriting)
    return fileURL
  }
}

private actor RoutedFixtureDownloader: ArtifactDownloading {
  private let responses: [URL: Data]
  private(set) var downloadCount = 0
  private(set) var requestedURLs = [URL]()

  init(responses: [URL: Data]) {
    self.responses = responses
  }

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
    guard let data = responses[sourceURL] else {
      throw URLError(.fileDoesNotExist)
    }
    downloadCount += 1
    requestedURLs.append(sourceURL)
    if let onBytes {
      onBytes(UInt64(data.count / 2))
      onBytes(UInt64(data.count))
    }
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "omarchy-routed-download-\(UUID().uuidString.lowercased())"
    )
    try data.write(to: fileURL, options: .withoutOverwriting)
    return fileURL
  }
}

private final class ProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = [ArtifactStagingProgress]()

  var events: [ArtifactStagingProgress] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  var handler: ArtifactStagingProgressHandler {
    { [self] event in
      lock.lock()
      storage.append(event)
      lock.unlock()
    }
  }
}

private func assertThrows<T>(
  _ expression: @autoclosure () async throws -> T,
  handler: (any Error) -> Void
) async {
  do {
    _ = try await expression()
    XCTFail("Expected expression to throw")
  } catch {
    handler(error)
  }
}

private final class SlowHTTPServer: @unchecked Sendable {
  private let listener: NWListener
  private let lock = NSLock()
  private var connections: [NWConnection] = []
  private var startContinuation: CheckedContinuation<URL, any Error>?

  init() throws {
    listener = try NWListener(using: .tcp, on: .any)
  }

  func start() async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock { startContinuation = continuation }
      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          guard let port = self.listener.port else { return }
          self.resumeStart(
            .success(URL(string: "http://127.0.0.1:\(port.rawValue)/payload.bin")!))
        case .failed(let error):
          self.resumeStart(.failure(error))
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        guard let self else { return }
        self.lock.withLock { self.connections.append(connection) }
        connection.start(queue: .global())
        let header = Data("HTTP/1.1 200 OK\r\nContent-Length: 50000000\r\n\r\n".utf8)
        connection.send(content: header, completion: .contentProcessed { _ in })
      }
      listener.start(queue: .global())
    }
  }

  func stop() {
    let pending = lock.withLock { () -> [NWConnection] in
      let current = connections
      connections.removeAll()
      return current
    }
    for connection in pending {
      connection.cancel()
    }
    listener.cancel()
  }

  private func resumeStart(_ result: Result<URL, any Error>) {
    let pending = lock.withLock { () -> CheckedContinuation<URL, any Error>? in
      let value = startContinuation
      startContinuation = nil
      return value
    }
    pending?.resume(with: result)
  }
}

private final class ByteRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = [UInt64]()

  var values: [UInt64] { lock.withLock { storage } }

  var handler: ArtifactByteProgressHandler {
    { [self] bytes in lock.withLock { storage.append(bytes) } }
  }
}

/// Serves one payload over HTTP/1.1 with keep-alive. Honors `Range: bytes=a-b`
/// unless told not to, can cut the first `drops` responses off halfway (with a
/// clean FIN), and records every request's Range header.
private final class RangeHTTPServer: @unchecked Sendable {
  private let payload: Data
  private let honorsRange: Bool
  private let failFirstWith: Int?
  private let responseDelay: DispatchTimeInterval
  private let listener: NWListener
  private let lock = NSLock()
  private var connections: [NWConnection] = []
  private var dropsLeft: Int
  private var activeRequests = 0
  private var requests = [String?]()
  private var encodings = [String?]()
  private var peak = 0
  private var startContinuation: CheckedContinuation<URL, any Error>?

  init(
    payload: Data,
    honorsRange: Bool = true,
    drops: Int = 0,
    failFirstWith: Int? = nil,
    responseDelay: DispatchTimeInterval = .never
  ) throws {
    self.payload = payload
    self.honorsRange = honorsRange
    self.failFirstWith = failFirstWith
    self.dropsLeft = drops
    self.responseDelay = responseDelay
    listener = try NWListener(using: .tcp, on: .any)
  }

  var rangeHeaders: [String?] { lock.withLock { requests } }
  var acceptEncodings: [String?] { lock.withLock { encodings } }
  var peakActiveRequests: Int { lock.withLock { peak } }
  var connectionCount: Int { lock.withLock { connections.count } }

  func start() async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock { startContinuation = continuation }
      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          guard let port = self.listener.port else { return }
          self.resumeStart(
            .success(URL(string: "http://127.0.0.1:\(port.rawValue)/payload.bin")!))
        case .failed(let error):
          self.resumeStart(.failure(error))
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        guard let self else { return }
        self.lock.withLock { self.connections.append(connection) }
        connection.start(queue: .global())
        self.receiveRequest(on: connection, buffer: Data())
      }
      listener.start(queue: .global())
    }
  }

  func stop() {
    let pending = lock.withLock { () -> [NWConnection] in
      let current = connections
      connections.removeAll()
      return current
    }
    for connection in pending {
      connection.cancel()
    }
    listener.cancel()
  }

  private func receiveRequest(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let data {
        buffer.append(data)
      }
      if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
        self.respond(to: String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
      } else if isComplete || error != nil {
        connection.cancel()
      } else {
        self.receiveRequest(on: connection, buffer: buffer)
      }
    }
  }

  private func respond(to head: String, on connection: NWConnection) {
    func header(_ name: String) -> String? {
      head.components(separatedBy: "\r\n")
        .first { $0.lowercased().hasPrefix("\(name):") }
        .map { $0.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces) }
    }
    let range = header("range")
    var status = "200 OK"
    var extra = ""
    var body = payload
    if honorsRange, let range, range.hasPrefix("bytes=") {
      let bounds = range.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
      let first = bounds[0]
      let last = min(bounds[1], payload.count - 1)
      body = payload.subdata(in: first..<(last + 1))
      status = "206 Partial Content"
      extra = "Content-Range: bytes \(first)-\(last)/\(payload.count)\r\n"
    }
    let failure = lock.withLock { () -> Int? in
      defer {
        requests.append(range)
        encodings.append(header("accept-encoding"))
      }
      return requests.isEmpty ? failFirstWith : nil
    }
    if let failure {
      connection.send(
        content: Data("HTTP/1.1 \(failure) Failed\r\nContent-Length: 0\r\n\r\n".utf8),
        completion: .contentProcessed { [weak self] _ in
          self?.receiveRequest(on: connection, buffer: Data())
        })
      return
    }
    let drop = lock.withLock { () -> Bool in
      activeRequests += 1
      peak = max(peak, activeRequests)
      guard dropsLeft > 0 else { return false }
      dropsLeft -= 1
      return true
    }
    let head = Data("HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\n\(extra)\r\n".utf8)
    let sent = drop ? body.prefix(body.count / 2) : body
    let send: @Sendable () -> Void = {
      connection.send(
        content: head + sent,
        completion: .contentProcessed { [weak self] _ in
          guard let self else { return }
          self.lock.withLock { self.activeRequests -= 1 }
          if drop {
            // Close only after the client has read the half body, like a link
            // that dies mid-transfer.
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) {
              connection.send(
                content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in })
            }
          } else {
            self.receiveRequest(on: connection, buffer: Data())
          }
        })
    }
    if responseDelay == .never {
      send()
    } else {
      DispatchQueue.global().asyncAfter(deadline: .now() + responseDelay, execute: send)
    }
  }

  private func resumeStart(_ result: Result<URL, any Error>) {
    let pending = lock.withLock { () -> CheckedContinuation<URL, any Error>? in
      let value = startContinuation
      startContinuation = nil
      return value
    }
    pending?.resume(with: result)
  }
}
