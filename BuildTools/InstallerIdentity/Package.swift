// swift-tools-version: 6.0

import PackageDescription

// Pure build tools shared by the main installer and macOS 13 Recovery target.
let package = Package(
  name: "InstallerIdentity",
  platforms: [.macOS(.v13)],
  products: [
    .plugin(name: "OmarchyInstallerIdentityPlugin", targets: ["OmarchyInstallerIdentityPlugin"])
  ],
  targets: [
    .executableTarget(name: "OmarchyInstallerIdentityGenerator"),
    .plugin(
      name: "OmarchyInstallerIdentityPlugin",
      capability: .buildTool(),
      dependencies: ["OmarchyInstallerIdentityGenerator"]
    ),
  ]
)
