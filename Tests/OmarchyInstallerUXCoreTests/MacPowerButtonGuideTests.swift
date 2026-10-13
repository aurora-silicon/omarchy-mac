#if os(macOS)
  import XCTest
  @testable import OmarchyInstallerUXCore

  final class MacPowerButtonGuideTests: XCTestCase {
    func testNotebookAndCompactDesktopSelection() {
      for id in ["apple,j293", "apple,j413", "apple,j414s", "apple,j700"] {
        XCTAssertEqual(MacPowerButtonGuide(deviceIdentifier: id, modelIdentifier: ""), .notebook)
      }
      for id in ["apple,j274", "apple,j473", "apple,j474s", "apple,j375c", "apple,j475d"] {
        XCTAssertEqual(MacPowerButtonGuide(deviceIdentifier: id, modelIdentifier: ""), .desktopRear)
      }
    }

    func testUndersideButtonDoesNotUseRearButtonArtwork() {
      for model in ["Mac16,10", "Mac16,11"] {
        let guide = MacPowerButtonGuide(deviceIdentifier: "unknown", modelIdentifier: model)
        XCTAssertEqual(guide, .desktopUnderside)
        XCTAssertNil(guide.assetName)
        XCTAssertTrue(guide.holdInstruction.contains("underside"))
      }
    }

    func testUnknownAndOtherEnclosuresUseGenericGuidance() {
      for id in ["unknown", "apple,j456", "apple,j180d"] {
        let guide = MacPowerButtonGuide(deviceIdentifier: id, modelIdentifier: "unknown")
        XCTAssertEqual(guide, .generic)
        XCTAssertNil(guide.assetName)
      }
    }
  }
#endif
