#if os(macOS)
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  /// The Mac catalog workflow signs with OpenSSL on a Linux runner
  /// (scripts/catalog_release.py). Fixtures/ci-signed-catalog holds an edge
  /// envelope that path wrote with a throwaway key, for fixture inputs, and
  /// that key's public half: the app must accept it exactly as it accepts a
  /// catalog signed with CryptoKit.
  final class CISignedCatalogTests: XCTestCase {
    func testTheAppAcceptsACatalogSignedByTheCIPath() throws {
      let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        .appendingPathComponent("ci-signed-catalog")
      let publicKey = try Data(
        contentsOf: fixtures.appendingPathComponent("trust-root.ed25519.pub"))
      let documents = try SignedCatalogEnvelope.decode(
        Data(contentsOf: fixtures.appendingPathComponent("catalog-edge.signed.json")))
      let trustRoot = try AppOwnedTrustRoot(
        rawRepresentation: publicKey,
        expectedFingerprint: SHA256Digest(hashing: publicKey).rawValue)

      let catalog = try AppleInstallerTrustCore().validateSupportCatalog(
        payload: documents.payload, signature: documents.signature,
        trustRoot: trustRoot, now: Date())

      XCTAssertEqual(catalog.deviceIdentifiers.count, 34)
      // An M1, an M2 and an M3 (marked untested, a key the app ignores).
      for model in ["apple,j274", "apple,j413", "apple,j613"] {
        guard case .admitted(let record) = catalog.admission(for: model) else {
          return XCTFail("\(model) must be admitted")
        }
        XCTAssertEqual(record.evidenceRevision, "omarchy-mac-edge-2026.10.14-0123456789ab")
        XCTAssertEqual(record.payloadDigest, record.delivery?.payload.expectedDigest)
        XCTAssertEqual(record.delivery?.payload.parts.count, 2)
      }
      XCTAssertEqual(
        catalog.admission(for: "apple,j614s"), .unsupported(deviceIdentifier: "apple,j614s"))

      var tampered = documents.payload
      tampered[tampered.startIndex + 10] ^= 0x01
      XCTAssertThrowsError(
        try AppleInstallerTrustCore().validateSupportCatalog(
          payload: tampered, signature: documents.signature, trustRoot: trustRoot, now: Date()))
    }
  }
#endif
