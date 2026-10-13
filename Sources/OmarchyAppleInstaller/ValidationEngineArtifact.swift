#if os(macOS)
  import Foundation

  public enum ValidationEngineArtifactError: Error, Equatable, Sendable {
    case unavailable
  }

  /// Locates the engine bundled inside the app.
  ///
  /// This copy exists only to inspect the Mac before anything is downloaded,
  /// which is what lets the app refuse a Mac that already runs Omarchy without
  /// touching the network. The engine that plans and performs an install comes
  /// from the signed catalog instead, so the two versions are deliberately
  /// allowed to differ. The bundled v0.9.2 engine recognizes M3 devices without
  /// expert mode; the older v0.9.0 bundle refused them before catalog loading.
  /// The .18 overlay also reports tight-disk candidates and keeps allocation
  /// recommendations separate from the safety limits used after staging.
  /// An installation engine fix ships in a catalog without rebuilding
  /// and re-notarizing the app. Nothing may require them to be equal.
  public struct ValidationEngineArtifactLocator: Sendable {
    public static let version = "v0.9.2-omarchy.38"
    public static let fileName = "installer-v0.9.2-omarchy.38.tar.gz"
    public static let expectedDigest =
      "sha256:2a9037f83a9986b6948a94bb31aed99958cb537b74ddb9e5e5254e6866a7d56f"
    public static let expectedSizeBytes: UInt64 = 17_864_537

    public init() {}

    public func locate() throws -> PinnedAsahiEngineArchive {
      try locate(
        environment: ProcessInfo.processInfo.environment,
        currentDirectory: URL(
          fileURLWithPath: FileManager.default.currentDirectoryPath,
          isDirectory: true
        ),
        resourceDirectory: Bundle.main.resourceURL
      )
    }

    public func locate(in bundle: Bundle) throws -> PinnedAsahiEngineArchive {
      try locate(
        environment: [:], currentDirectory: bundle.bundleURL,
        resourceDirectory: bundle.resourceURL)
    }

    func locate(
      environment: [String: String],
      currentDirectory: URL,
      resourceDirectory: URL?
    ) throws -> PinnedAsahiEngineArchive {
      var candidates = [URL]()
      if let override = environment["OMARCHY_VALIDATION_ENGINE_ARCHIVE"],
        !override.isEmpty
      {
        candidates.append(URL(fileURLWithPath: override))
      }
      if let resourceDirectory {
        candidates.append(
          resourceDirectory
            .appendingPathComponent("Engine", isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(Self.fileName)
        )
      }
      candidates.append(
        currentDirectory
          .appendingPathComponent("Engine", isDirectory: true)
          .appendingPathComponent("artifacts", isDirectory: true)
          .appendingPathComponent(Self.fileName)
      )
      candidates.append(
        currentDirectory
          .appendingPathComponent("apps", isDirectory: true)
          .appendingPathComponent("omarchy-apple-installer", isDirectory: true)
          .appendingPathComponent("Engine", isDirectory: true)
          .appendingPathComponent("artifacts", isDirectory: true)
          .appendingPathComponent(Self.fileName)
      )

      guard
        let fileURL = candidates.first(where: {
          FileManager.default.fileExists(atPath: $0.path)
        })
      else {
        throw ValidationEngineArtifactError.unavailable
      }
      return try PinnedAsahiEngineArchive(
        fileURL: fileURL,
        expectedDigest: Self.expectedDigest,
        expectedSizeBytes: Self.expectedSizeBytes
      )
    }
  }
#endif
