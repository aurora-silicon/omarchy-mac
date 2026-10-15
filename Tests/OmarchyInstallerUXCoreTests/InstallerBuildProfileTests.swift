#if os(macOS)
  import OmarchyAppleInstallerTrustCore
  import XCTest
  @testable import OmarchyInstallerUXCore

  final class InstallerBuildProfileTests: XCTestCase {
    func testStandardProfileBootsLimine() {
      let profile = InstallerBuildProfile.resolve(infoDictionary: [:])
      XCTAssertEqual(profile, .standard)
      XCTAssertTrue(profile.allowsEncryption)
      XCTAssertTrue(profile.showsReleaseChannels)
      XCTAssertEqual(profile.workspaceName, InstallerProductIdentity.appIdentifier)
      // Stable images and the images this repository builds boot Limine.
      XCTAssertEqual(profile.startupSequence, "m1n1 → U-Boot → Limine → Omarchy")
      XCTAssertEqual(
        PlainLanguage.doneVerifiedRows(profile: profile).first?.value, profile.startupSequence)
    }

    func testLegacyPlainProfileRemainsIsolatedAndCannotEncrypt() {
      let profile = InstallerBuildProfile.resolve(infoDictionary: ["OmarchyPrivatePlainTest": true])
      XCTAssertEqual(profile, .privatePlain)
      XCTAssertFalse(profile.allowsEncryption)
      XCTAssertFalse(profile.showsReleaseChannels)
      XCTAssertEqual(
        profile.workspaceName, InstallerProductIdentity.appIdentifier + ".private-m3-20260922")
      XCTAssertTrue(profile.startupSequence.contains("GRUB"))
    }

    func testPrivateLimineCanEncryptWithoutUsingPublicOrChrisState() {
      let profile = InstallerBuildProfile.resolve(infoDictionary: ["OmarchyPrivateLimineTest": true]
      )
      XCTAssertEqual(profile, .privateLimine)
      XCTAssertTrue(profile.allowsEncryption)
      XCTAssertFalse(profile.showsReleaseChannels)
      XCTAssertEqual(
        profile.workspaceName, InstallerProductIdentity.appIdentifier + ".private-limine-20260922")
      XCTAssertNotEqual(profile.workspaceName, InstallerBuildProfile.standard.workspaceName)
      XCTAssertNotEqual(profile.workspaceName, InstallerBuildProfile.privatePlain.workspaceName)
      XCTAssertTrue(profile.startupSequence.contains("Limine"))
      XCTAssertFalse(profile.startupSequence.contains("GRUB"))
    }

    func testDeveloperBuildKeepsItsOwnStateAndHidesChannels() {
      let profile = InstallerBuildProfile.resolve(infoDictionary: ["OmarchyDeveloperBuild": true])
      XCTAssertEqual(profile, .developer)
      XCTAssertTrue(profile.allowsEncryption)
      XCTAssertFalse(profile.showsReleaseChannels)
      XCTAssertEqual(profile.workspaceName, InstallerProductIdentity.appIdentifier + ".developer")
      for other in [InstallerBuildProfile.standard, .privatePlain, .privateLimine] {
        XCTAssertNotEqual(profile.workspaceName, other.workspaceName)
      }
      XCTAssertEqual(profile.startupSequence, "m1n1 → U-Boot → Limine → Omarchy")
    }

    func testPrivateFlagsOutrankTheDeveloperFlag() {
      let profile = InstallerBuildProfile.resolve(infoDictionary: [
        "OmarchyDeveloperBuild": true, "OmarchyPrivatePlainTest": true,
      ])
      XCTAssertEqual(profile, .privatePlain)
    }

    func testConflictingFlagsRetainPlainRestriction() {
      let profile = InstallerBuildProfile.resolve(infoDictionary: [
        "OmarchyPrivatePlainTest": true, "OmarchyPrivateLimineTest": true,
      ])
      XCTAssertEqual(profile, .privatePlain)
      XCTAssertFalse(profile.allowsEncryption)
    }

  }
#endif
