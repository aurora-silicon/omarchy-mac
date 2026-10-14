#if os(macOS)
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class AdHocInstallerHelperBlesserTests: XCTestCase {
    func testAppleScriptStringsCannotEndEarly() {
      XCTAssertEqual(
        AdHocInstallerHelperBlesser.appleScriptString(#"pa"ss\word"#), #""pa\"ss\\word""#)
    }

    func testShellArgumentsCannotEndEarly() {
      XCTAssertEqual(AdHocInstallerHelperBlesser.shellQuote("it's"), #"'it'\''s'"#)
    }

    func testABundleWithoutAHelperCannotInstallOne() throws {
      let bundle = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".app")
      try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: bundle) }
      XCTAssertFalse(AdHocInstallerHelperBlesser.isAvailable(in: bundle))
      XCTAssertThrowsError(try AdHocInstallerHelperBlesser(bundle: bundle).shellCommand())
    }
  }
#endif
