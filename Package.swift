// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "OmarchyAppleInstallerTrustCore",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(
      name: "OmarchyAppleInstallerTrustCore",
      targets: ["OmarchyAppleInstallerTrustCore"]
    ),
    .library(
      name: "OmarchyInstallerUXCore",
      targets: ["OmarchyInstallerUXCore"]
    ),
    .executable(
      name: "OmarchyAppleInstallerApp",
      targets: ["OmarchyAppleInstallerApp"]
    ),
    .executable(
      name: "OmarchyAppleInstallerHelper",
      targets: ["OmarchyAppleInstallerHelper"]
    ),
    .executable(
      name: "OmarchyCanaryCandidateTool",
      targets: ["OmarchyCanaryCandidateTool"]
    ),
    .executable(
      name: "OmarchyCanaryPhysicalTool",
      targets: ["OmarchyCanaryPhysicalTool"]
    ),
  ],
  targets: [
    .target(name: "RecoveryAuthorization", path: "Recovery/Native", publicHeadersPath: "."),
    .target(
      name: "RecoveryAccountCore", dependencies: ["RecoveryAuthorization"],
      path: "Recovery/Sources/Account"),
    .target(
      name: "OmarchyInstallerSystem",
      path: "Sources/OmarchyInstallerSystem",
      publicHeadersPath: "include"
    ),
    .executableTarget(
      name: "RecoveryAccountQualification",
      dependencies: ["RecoveryAccountCore"],
      path: "Development/RecoveryAccountQualification"
    ),
    .executableTarget(
      name: "InstallerReadinessCheck",
      dependencies: ["OmarchyAppleInstallerTrustCore"],
      path: "Development/ReadinessCheck"
    ),
    .executableTarget(
      name: "OmarchyInstallerIdentityGenerator",
      path: "Sources/OmarchyInstallerIdentityGenerator"
    ),
    .plugin(
      name: "OmarchyInstallerIdentityPlugin",
      capability: .buildTool(),
      dependencies: ["OmarchyInstallerIdentityGenerator"]
    ),
    .target(
      name: "OmarchyAppleInstallerTrustCore",
      dependencies: ["OmarchyInstallerSystem", "RecoveryAccountCore"],
      path: "Sources/OmarchyAppleInstaller",
      plugins: ["OmarchyInstallerIdentityPlugin"]
    ),
    .target(
      name: "OmarchyInstallerUXCore",
      dependencies: ["OmarchyAppleInstallerTrustCore", "RecoveryAccountCore"],
      path: "Sources/OmarchyInstallerUXCore"
    ),
    .executableTarget(
      name: "OmarchyAppleInstallerApp",
      dependencies: [
        "OmarchyAppleInstallerTrustCore",
        "OmarchyInstallerUXCore",
        "RecoveryAccountCore",
      ],
      path: "Sources/OmarchyAppleInstallerApp"
    ),
    .executableTarget(
      name: "OmarchyAppleInstallerHelper",
      dependencies: ["OmarchyAppleInstallerTrustCore"],
      path: "Sources/OmarchyAppleInstallerHelper"
    ),
    .executableTarget(
      name: "OmarchyCanaryCandidateTool",
      dependencies: ["OmarchyAppleInstallerTrustCore"],
      path: "Sources/OmarchyCanaryCandidateTool"
    ),
    .executableTarget(
      name: "OmarchyCanaryPhysicalTool",
      dependencies: ["OmarchyAppleInstallerTrustCore"],
      path: "Sources/OmarchyCanaryPhysicalTool"
    ),
    .testTarget(
      name: "OmarchyAppleInstallerTrustCoreTests",
      dependencies: ["OmarchyAppleInstallerTrustCore"],
      path: "Tests/OmarchyAppleInstallerTrustCoreTests",
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "OmarchyInstallerLifecycleTests",
      dependencies: ["OmarchyAppleInstallerTrustCore"],
      path: "Tests/OmarchyInstallerLifecycleTests"
    ),
    .testTarget(
      name: "OmarchyAppleInstallerAppTests",
      dependencies: ["OmarchyAppleInstallerApp"],
      path: "Tests/OmarchyAppleInstallerAppTests"
    ),
    .testTarget(
      name: "OmarchyInstallerUXCoreTests",
      dependencies: ["OmarchyInstallerUXCore"],
      path: "Tests/OmarchyInstallerUXCoreTests"
    ),
  ]
)
