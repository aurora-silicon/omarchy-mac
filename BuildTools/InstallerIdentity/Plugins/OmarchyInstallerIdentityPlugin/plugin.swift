import Foundation
import PackagePlugin

@main
struct OmarchyInstallerIdentityPlugin: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: any Target) throws -> [Command] {
    let packageDirectory = context.package.directoryURL
    let identityRoot =
      FileManager.default.fileExists(
        atPath: packageDirectory.appending(components: "Packaging", "identity.conf").path
      ) ? packageDirectory : packageDirectory.deletingLastPathComponent()
    let configuration = identityRoot.appending(components: "Packaging", "identity.conf")
    let output = context.pluginWorkDirectoryURL
      .appending(component: "InstallerBuildConfiguration.swift")
    return [
      .buildCommand(
        displayName: "Generating installer identity from Packaging/identity.conf",
        executable: try context.tool(named: "OmarchyInstallerIdentityGenerator").url,
        arguments: [
          configuration.path(percentEncoded: false),
          output.path(percentEncoded: false),
        ],
        inputFiles: [configuration],
        outputFiles: [output]
      )
    ]
  }
}
