import AppKit
import OmarchyInstallerUXCore
import SwiftUI

struct RecoveryHandoffView: View {
  let volumeName: String
  var session: InstallerSession? = nil
  @State private var busy = false
  @State private var failure: String?
  @State private var showingShutdownPreview = false
  @State private var showingFailure = false
  @State private var showingDetails = false
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
        Text(
          session?.usesLegacyRecovery == true
            ? "Have your macOS owner’s password ready. Follow Finish Installation to complete setup."
            : "Have your macOS owner’s password ready. You’ll create your recovery account there."
        )
          .font(OmarchyTheme.detail).foregroundStyle(OmarchyTheme.secondaryText)
      }.font(OmarchyTheme.body)
    } actions: {
      HStack(spacing: 12) {
        ProgressView().controlSize(.small)
          .frame(width: 16, height: 16).opacity(busy ? 1 : 0)
          .accessibilityHidden(!busy).accessibilityLabel("Preparing shutdown")
        Button(shutdownConfirmed ? "YES, I HAVE READ, SHUT DOWN" : "Shut Down", action: shutDown)
          .omarchyPrimaryButton().disabled(busy)
        Color.clear.frame(width: 16, height: 16).accessibilityHidden(true)
      }
    }
    .foregroundStyle(OmarchyTheme.text)
    .alert("Shut Down", isPresented: $showingShutdownPreview) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("The installed flow shuts down here. This simulation keeps your Mac running.")
    }
    .alert("Couldn’t prepare shutdown", isPresented: $showingFailure) {
      Button("Show details") { showingDetails = true }
      Button("OK", role: .cancel) {}
    } message: {
      Text("The startup setup needs attention before you shut down.")
    }
    .sheet(isPresented: $showingDetails) {
      VStack(alignment: .leading, spacing: 16) {
        Text("Shutdown details").font(.headline)
        ScrollView {
          Text(failure ?? "").textSelection(.enabled).frame(
            maxWidth: .infinity, alignment: .leading)
        }
        HStack {
          Spacer()
          Button("Done") { showingDetails = false }
        }
      }.padding(24).frame(width: 520, height: 280)
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
          showingFailure = true
        }
      } catch {
        failure = error.localizedDescription
        showingFailure = true
      }
    }
  }
}
