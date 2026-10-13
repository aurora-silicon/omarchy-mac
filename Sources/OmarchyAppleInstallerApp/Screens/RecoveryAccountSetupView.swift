import AppKit
import OmarchyAppleInstallerTrustCore
import OmarchyInstallerUXCore
import SwiftUI

struct RecoveryAccountSetupView: View {
  let volumeName: String
  var session: InstallerSession? = nil
  @State private var input = RecoveryAccountDraft()
  @State private var accountPrepared = false
  @State private var busy = false
  @State private var failure: String?
  @FocusState private var focused: Field?
  private enum Field: Hashable { case username, password, confirmation }
  private var finalized: Bool { session?.recoveryAccount?.record?.phase == "finalized" }

  var body: some View {
    InstallerPageLayout {
      Color.clear.frame(height: 24).accessibilityHidden(true)
    } content: {
      content
    } actions: {
      if finalized {
        Button("Shut Down") {
          if session?.shutdownAfterAccountSetup() != true {
            failure = "Choose Apple menu → Shut Down after saving your work."
          }
        }.omarchyPrimaryButton()
      } else if accountPrepared {
        HStack(spacing: 18) {
          Button("Check Authorization") { checkAuthorization() }
            .omarchySecondaryButton()
          Button("Open Startup Disk", action: openStartupDisk)
            .omarchyPrimaryButton()
            .keyboardShortcut(.defaultAction)
        }.disabled(busy)
      } else {
        Button("Create Recovery Account", action: prepareAccount)
          .omarchyPrimaryButton()
          .disabled(!input.isValid || busy)
          .keyboardShortcut(.defaultAction)
      }
    }
    .foregroundStyle(OmarchyTheme.text)
    .onDisappear { input.clearPasswords() }
    .onAppear {
      if let record = session?.recoveryAccount?.record {
        input.username = record.username
        accountPrepared = record.phase != "creating"
      }
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 22) {
      if finalized {
        VStack(alignment: .leading, spacing: 18) {
          Text("Recovery account ready").font(OmarchyTheme.title)
          Text("Shut down, then hold the power button until Loading startup options appears.")
          Text("Choose \(volumeName) → Finish Installation and sign in as \(input.username).")
        }.font(OmarchyTheme.body)
      } else if accountPrepared {
        authorizationInstructions
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text("Create a recovery account")
            .font(OmarchyTheme.title)
          Text(
            "Use this account to manage \(volumeName) in Recovery.\nYour Linux login is separate."
          )
          .font(OmarchyTheme.body).foregroundStyle(OmarchyTheme.secondaryText)
        }
        VStack(alignment: .leading, spacing: 14) {
          field("Username", issue: input.usernameIssue) {
            TextField("omarchy-owner", text: $input.username)
              .textContentType(.username).autocorrectionDisabled()
              .focused($focused, equals: .username)
              .onSubmit { focused = .password }
          }
          field("Password", issue: input.passwordIssue) {
            SecureField("", text: $input.password)
              .textContentType(.newPassword).privacySensitive()
              .focused($focused, equals: .password)
              .onSubmit { focused = .confirmation }
          }
          field("Retype password", issue: input.confirmationIssue) {
            SecureField("", text: $input.confirmation)
              .textContentType(.newPassword).privacySensitive()
              .focused($focused, equals: .confirmation)
              .onSubmit(prepareAccount)
          }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .disabled(busy)
      }
      if busy { ProgressView("Preparing recovery account…").controlSize(.small) }
      if let failure {
        Text(failure).font(OmarchyTheme.detail).foregroundStyle(OmarchyTheme.caution)
          .textSelection(.enabled)
      }
    }
  }

  private var authorizationInstructions: some View {
    VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: 8) {
        Text(
          session?.recoveryAccount?.record?.phase == "finalized"
            ? "Recovery account ready" : "Authorize \(volumeName)"
        )
        .font(OmarchyTheme.title)
        Text("Finish in Startup Disk to enable your recovery account.")
          .font(OmarchyTheme.body).foregroundStyle(OmarchyTheme.secondaryText)
      }
      VStack(alignment: .leading, spacing: 20) {
        step(1, "Select \(volumeName)", "In System Settings → General → Startup Disk.")
        step(2, "Click Restart…", "Choose Authorize Users… when prompted.")
        step(
          3, "Authorize \(input.username)",
          "Use your new recovery password, then your existing macOS owner’s credentials when asked."
        )
      }
      Text("Startup Disk may restart your Mac after authorization.")
        .font(OmarchyTheme.detail).foregroundStyle(OmarchyTheme.secondaryText)
      if session != nil {
        field("Recovery password", issue: nil) {
          SecureField("Needed only to check authorization", text: $input.password)
            .privacySensitive().textFieldStyle(.roundedBorder)
        }
      }
    }
  }

  private func openStartupDisk() {
    if let session {
      if !session.openStartupDisk() {
        failure = "Couldn’t open Startup Disk. Open System Settings → General → Startup Disk."
      }
      return
    }
    let alert = NSAlert()
    alert.messageText = "Startup Disk · Simulation"
    alert.informativeText =
      "The installed flow will open Startup Disk here. This preview keeps your Mac running."
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  private func prepareAccount() {
    guard input.isValid else { return }
    if let session {
      let name = input.username
      let secret = Data(input.password.utf8)
      input.clearPasswords()
      focused = nil
      busy = true
      failure = nil
      Task { @MainActor in
        defer { busy = false }
        do {
          try await session.prepareRecoveryAccount(username: name, password: secret)
          accountPrepared = true
        } catch { failure = error.localizedDescription }
      }
      return
    }
    input.clearPasswords()
    focused = nil
    accountPrepared = true
  }

  private func checkAuthorization() {
    guard let session else { return }
    guard !input.password.isEmpty else {
      failure = "Enter the recovery account password to check authorization."
      return
    }
    let secret = Data(input.password.utf8)
    input.clearPasswords()
    busy = true
    failure = nil
    Task { @MainActor in
      defer { busy = false }
      do {
        try await session.finalizeRecoveryAccount(password: secret)
        if session.recoveryAccount?.record?.phase != "finalized" {
          failure =
            "The account is prepared. Complete Authorize Users in Startup Disk, then check again."
        }
      } catch { failure = error.localizedDescription }
    }
  }

  private func field<Content: View>(
    _ label: String, issue: String?, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(OmarchyTheme.body)
      content().accessibilityLabel(label)
      if let issue {
        Text(issue).font(OmarchyTheme.detail).foregroundStyle(OmarchyTheme.caution)
      }
    }
  }

  private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(number)").font(OmarchyTheme.body.weight(.semibold))
        .frame(width: 28, height: 28)
        .background(OmarchyTheme.card, in: Circle())
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(OmarchyTheme.body.weight(.semibold))
        Text(detail).font(OmarchyTheme.body).foregroundStyle(OmarchyTheme.secondaryText)
      }
    }
  }
}
