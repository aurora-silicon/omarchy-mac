#if DEBUG
  import AppKit
  import OmarchyAppleInstallerTrustCore
  import OmarchyInstallerUXCore
  import SwiftUI

  @MainActor @Observable
  final class SimulationControls {
    var scenario = launchScenario
    var channel = ReleaseChannel.edge
    var slow = false
    var dark = true
    var generation = UUID()
    var environment = InstallerSimulationEnvironment(scenario: launchScenario)
    var canChangeChannel = false
    var session: InstallerSession?
    var previewsRecoveryHandoff = false
    var removalScenario = RemovalPreviewScenario.success

    static var launchScenario: InstallerSimulationScenario {
      let prefix = "--simulate-scenario="
      guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) })
      else { return .success }
      return InstallerSimulationScenario(rawValue: String(argument.dropFirst(prefix.count)))
        ?? .success
    }

    func reset() {
      environment.cancel()
      environment = InstallerSimulationEnvironment(
        scenario: scenario, channel: channel,
        delay: slow ? .seconds(2) : .milliseconds(400))
      generation = UUID()
      canChangeChannel = false
      session = nil
      previewsRecoveryHandoff = false
    }

    func showGuidance() {
      let alert = NSAlert()
      alert.messageText = "Simulation"
      alert.informativeText =
        scenario.guidance + "\n\nUses test data. No accounts, disk changes or restarts."
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
  }

  struct SimulationDashboard: View {
    @Bindable var controls: SimulationControls
    var onSessionAvailable: ((InstallerSession) -> Void)? = nil

    var body: some View {
      Group {
        if controls.previewsRecoveryHandoff {
          RecoveryHandoffView(volumeName: "Omarchy")
        } else {
          OnePageInstallerView(
            environment: controls.environment, channel: controls.channel,
            onChannelAvailability: { controls.canChangeChannel = $0 },
            onSessionAvailable: {
              controls.session = $0
              onSessionAvailable?($0)
            }
          )
          .id(controls.generation)
          .task { await continueAtLaunch() }
        }
      }
      .preferredColorScheme(controls.dark ? .dark : .light)
      .onChange(of: controls.scenario) { _, _ in controls.reset() }
      .onChange(of: controls.slow) { _, _ in controls.reset() }
      .onChange(of: controls.channel) { _, _ in controls.reset() }
    }

    private func continueAtLaunch() async {
      guard ProcessInfo.processInfo.arguments.contains("--simulate-continue") else { return }
      for _ in 0..<100 {
        if Task.isCancelled { return }
        if let session = controls.session, case .welcome = session.phase {
          await session.continueToPlan()
          return
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }
#endif
