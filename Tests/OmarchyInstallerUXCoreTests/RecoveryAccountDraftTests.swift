#if os(macOS)
  import XCTest
  @testable import OmarchyInstallerUXCore

  final class RecoveryAccountDraftTests: XCTestCase {
    func testRequiresAllThreeFieldsAndMatchingPasswords() {
      var input = RecoveryAccountDraft()
      XCTAssertFalse(input.isValid)
      input.username = "omarchy-owner"
      input.password = "a-test-password"
      XCTAssertFalse(input.isValid)
      input.confirmation = "a-different-password"
      XCTAssertFalse(input.isValid)
      XCTAssertNotNil(input.confirmationIssue)
      input.confirmation = input.password
      XCTAssertTrue(input.isValid)
      input.clearPasswords()
      XCTAssertEqual(input.username, "omarchy-owner")
      XCTAssertTrue(input.password.isEmpty)
      XCTAssertTrue(input.confirmation.isEmpty)
      XCTAssertFalse(input.isValid)
    }

    func testMatchesTheNativeAccountCreatorsShortNameRules() {
      var input = RecoveryAccountDraft()
      input.password = "a-test-password"
      input.confirmation = input.password
      for name in ["a", "omarchy-owner", "owner_2", String(repeating: "a", count: 31)] {
        input.username = name
        XCTAssertTrue(input.isValid)
      }
      for name in [
        "", "2owner", "Owner", "owner name", "a/b", "a\n", String(repeating: "a", count: 32),
      ] {
        input.username = name
        XCTAssertFalse(input.isValid)
      }
    }

    func testRejectsEmptyPasswordsAndPromptSeparators() {
      var input = RecoveryAccountDraft()
      input.username = "owner"
      for password in ["", "long-password\n", "long-password\r", "long-password\0"] {
        input.password = password
        input.confirmation = password
        XCTAssertFalse(input.isValid)
      }
      for password in ["a", "short", "a longer password"] {
        input.password = password
        input.confirmation = password
        XCTAssertTrue(input.isValid)
      }
    }
  }
#endif
