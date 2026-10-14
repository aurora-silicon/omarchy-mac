// swift-tools-version: 5.9

import Foundation
import PackageDescription

let buildMode = ProcessInfo.processInfo.environment["OMARCHY_RECOVERY_BUILD"] ?? "preview"
precondition(["preview", "recovery"].contains(buildMode), "Unknown Recovery build mode")

// Recovery may run an older macOS than the main installer. Keep this target
// independent of the main application's macOS 15 requirement.
let package = Package(
  name: "OmarchyRecovery",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "OmarchyRecovery", targets: ["OmarchyRecovery"])],
  dependencies: [.package(path: "../BuildTools/InstallerIdentity")],
  targets: [
    .target(name: "RecoveryStandaloneAuthorization", path: "Native", publicHeadersPath: "."),
    .executableTarget(
      name: "OmarchyRecovery",
      dependencies: ["RecoveryStandaloneAuthorization"],
      path: "Sources",
      swiftSettings: [
        .define(buildMode == "recovery" ? "OMARCHY_STEP2_RECOVERY" : "OMARCHY_STEP2_PREVIEW")
      ],
      plugins: [.plugin(name: "OmarchyInstallerIdentityPlugin", package: "InstallerIdentity")]
    ),
  ]
)
