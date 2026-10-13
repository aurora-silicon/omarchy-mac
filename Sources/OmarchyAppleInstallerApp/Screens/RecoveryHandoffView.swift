import AppKit
import OmarchyInstallerUXCore
import SwiftUI

struct RecoveryHandoffView: View {
  let volumeName: String
  var session: InstallerSession? = nil
  @State private var busy = false
  @State private var failure: String?
  @State private var showingShutdownPreview = false
  @State private var shutdownConfirmed = false
  private var guide: MacPowerButtonGuide { session?.powerButtonGuide ?? .notebook }

  var body: some View {
    InstallerPageLayout {
      Color.clear.frame(height: 24).accessibilityHidden(true)
    } content: {
      VStack(alignment: .leading, spacing: 20) {
        Text("Start in Recovery").font(OmarchyTheme.title)
        HStack(spacing: 22) {
          if let name = guide.assetName,
            let url = Bundle.main.url(forResource: name, withExtension: "png"),
            let image = NSImage(contentsOf: url)
          {
            Image(nsImage: image)
              .resizable().interpolation(.high).scaledToFit()
              .frame(width: 242, height: 160)
              .accessibilityLabel(guide.location)
          } else {
            VStack(spacing: 12) {
              Image(systemName: "power").font(.system(size: 64, weight: .light))
              Text(guide.location).font(OmarchyTheme.detail).multilineTextAlignment(.center)
            }.frame(width: 242, height: 160)
          }
          VStack(alignment: .leading, spacing: 18) {
            step(1, "Shut down completely.")
            step(2, guide.holdInstruction)
            step(3, "Choose “\(volumeName)” → Finish Installation.")
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        Text("Don’t restart normally yet: unfinished setup can cause a boot loop.")
          .font(OmarchyTheme.detail).foregroundStyle(OmarchyTheme.caution)
        Text("Have your macOS owner’s password ready. You’ll create your recovery account there.")
          .font(OmarchyTheme.detail).foregroundStyle(OmarchyTheme.secondaryText)
        if busy { ProgressView("Preparing Recovery…").controlSize(.small) }
        if let failure {
          Text(failure).font(OmarchyTheme.detail).foregroundStyle(OmarchyTheme.caution)
        }
      }.font(OmarchyTheme.body)
    } actions: {
      Button(shutdownConfirmed ? "YES, I HAVE READ, SHUT DOWN" : "Shut Down", action: shutDown)
        .omarchyPrimaryButton().disabled(busy)
    }
    .foregroundStyle(OmarchyTheme.text)
    .alert("Shut Down", isPresented: $showingShutdownPreview) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("The installed flow shuts down here. This simulation keeps your Mac running.")
    }
  }

  private func step(_ number: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(String(number)).font(OmarchyTheme.detail.weight(.semibold))
        .foregroundStyle(OmarchyTheme.secondaryText)
      Text(text).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func shutDown() {
    guard shutdownConfirmed else {
      shutdownConfirmed = true
      return
    }
    guard let session else {
      showingShutdownPreview = true
      return
    }
    busy = true
    failure = nil
    Task { @MainActor in
      defer { busy = false }
      do {
        let accepted = try await session.prepareRecoveryHandoffAndShutdown()
        if !accepted {
          failure = "Choose Apple menu → Shut Down after saving your work."
        }
      } catch { failure = error.localizedDescription }
    }
  }
}
