#if DEBUG
  import AppKit
  import OmarchyInstallerUXCore
  import SwiftUI

  /// Preview of the final account and Startup Disk handoff. It performs no
  /// account creation, ownership grant, Settings launch or reboot.
  struct RecoveryAccountSetupView: View {
    let volumeName: String
    @State private var input = RecoveryAccountDraft()
    @State private var accountPrepared = false
    @FocusState private var focused: Field?
    private enum Field: Hashable { case username, password, confirmation }

    var body: some View {
      InstallerPageLayout {
        Color.clear.frame(height: 24).accessibilityHidden(true)
      } content: {
        content
      } actions: {
        if accountPrepared {
          Button("Open Startup Disk", action: previewStartupDisk)
            .omarchyPrimaryButton()
            .keyboardShortcut(.defaultAction)
        } else {
          Button("Create Recovery Account", action: prepareAccount)
            .omarchyPrimaryButton()
            .disabled(!input.isValid)
            .keyboardShortcut(.defaultAction)
        }
      }
      .foregroundStyle(OmarchyTheme.text)
      .onDisappear { input.clearPasswords() }
    }

    private var content: some View {
      VStack(alignment: .leading, spacing: 22) {
        if accountPrepared {
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
        }
      }
    }

    private var authorizationInstructions: some View {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Authorize \(volumeName)")
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

      }
    }

    private func previewStartupDisk() {
      let alert = NSAlert()
      alert.messageText = "Startup Disk · Simulation"
      alert.informativeText =
        "The installed flow will open Startup Disk here. This preview keeps your Mac running."
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }

    private func prepareAccount() {
      guard input.isValid else { return }
      input.clearPasswords()
      focused = nil
      accountPrepared = true
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
#endif
