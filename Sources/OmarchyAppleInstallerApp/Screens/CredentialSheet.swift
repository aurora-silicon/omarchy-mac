import AppKit
import OmarchyAppleInstallerTrustCore
import OmarchyInstallerUXCore
import SwiftUI

/// Screen C — the machine-owner authorization sheet.
///
/// Password lifecycle (unchanged from the previous view): the password exists
/// only as sheet-local state, is converted straight into a
/// `MachineOwnerAuthorization` on submit, and is cleared at the same three
/// points — on submit, on cancel, and unconditionally on disappear. Nothing
/// above the XPC boundary can retain the string: the session and environment
/// APIs accept only `MachineOwnerAuthorization`.
struct CredentialSheet: View {
  let context: CredentialSheetContext
  let isSimulation: Bool
  let approvedSize: String?
  let onCancel: () -> Void
  let onSubmit: (MachineOwnerAuthorization) -> Void
  /// Asks whether the helper is switched off, as the sheet appears.
  var onCheckHelper: () async -> Void = {}

  @State private var input = CredentialInput(username: "")
  @FocusState private var focus: Field?

  private enum Field: Hashable {
    case username
    case password
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(isRetry ? PlainLanguage.authorizeRetryTitle : PlainLanguage.authorizeTitle)
        .font(OmarchyTheme.title)
        .foregroundStyle(OmarchyTheme.accent)

      Text(
        isSimulation
          ? "This simulation uses a test account. No real password is needed."
          : "Use a macOS account that is allowed to install on this Mac. Your password approves the disk changes you reviewed and the final setup."
      )
      .font(OmarchyTheme.body)
      .fixedSize(horizontal: false, vertical: true)

      HStack {
        Text(isRetry ? "Approved operation" : "Space for Omarchy")
          .foregroundStyle(OmarchyTheme.secondaryText)
        Spacer()
        Text(isRetry ? "Recovery authorization only" : approvedSize ?? "Reviewed size")
          .fontWeight(.medium)
      }
      .font(OmarchyTheme.body)
      .padding(12)
      .background(OmarchyTheme.card, in: RoundedRectangle(cornerRadius: 4))

      if context.helperSwitchedOff && !isSimulation {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "switch.2")
          Text(PlainLanguage.authorizeHelperSwitchedOffNotice)
        }
        .font(OmarchyTheme.detail)
        .foregroundStyle(OmarchyTheme.caution)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
      } else if context.mentionsBackgroundItem && !isSimulation {
        Text(PlainLanguage.authorizeBackgroundItemNotice)
          .font(OmarchyTheme.detail)
          .foregroundStyle(OmarchyTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }

      field(label: PlainLanguage.authorizeUsernameLabel, reason: input.usernameReason) {
        TextField("", text: isSimulation ? .constant("simulation") : $input.username)
          .textFieldStyle(.roundedBorder)
          .textContentType(.username)
          .accessibilityLabel(PlainLanguage.authorizeUsernameLabel)
          .autocorrectionDisabled()
          .focused($focus, equals: .username)
          .onSubmit { focus = .password }
          .disabled(isSimulation)
      }
      field(label: PlainLanguage.authorizePasswordLabel, reason: input.passwordReason) {
        SecureField("", text: isSimulation ? .constant("simulation-only") : $input.password)
          .textFieldStyle(.roundedBorder)
          .textContentType(.password)
          .accessibilityLabel(PlainLanguage.authorizePasswordLabel)
          .privacySensitive()
          .focused($focus, equals: .password)
          .onSubmit(submit)
          .disabled(isSimulation)
      }

      if !context.isVerifying, let message = errorMessage {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "exclamationmark.triangle")
          Text(message).foregroundStyle(OmarchyTheme.danger)
        }
        .font(OmarchyTheme.detail)
        .foregroundStyle(OmarchyTheme.secondaryText)
        .lineSpacing(OmarchyTheme.helpLineSpacing)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
      }

      HStack(spacing: 12) {
        if context.helperSwitchedOff && !isSimulation {
          Button(PlainLanguage.openLoginItems) {
            NSWorkspace.shared.open(PlainLanguage.loginItemsSettingsURL)
          }
          .omarchySecondaryButton()
          .fixedSize()
          .focusEffectDisabled()
        }
        Spacer(minLength: 0)
        ProgressView().controlSize(.small)
          .frame(width: 16, height: 16)
          .opacity(context.isVerifying ? 1 : 0)
          .accessibilityLabel(PlainLanguage.authorizeChecking)
          .accessibilityHidden(!context.isVerifying)
        Button(PlainLanguage.authorizeCancel, action: cancel)
          .omarchySecondaryButton()
          .fixedSize()
          .keyboardShortcut(.cancelAction)
          .focusEffectDisabled()
        Button(primaryTitle, action: submit)
          .omarchyPrimaryButton()
          .fixedSize()
          .keyboardShortcut(.defaultAction)
          .disabled(!input.isValid)
      }
      .padding(.top, 8)
    }
    .padding(24)
    .frame(width: 456)
    .omarchyTypography()
    .foregroundStyle(OmarchyTheme.text)
    .background(OmarchyTheme.window)
    .disabled(context.isVerifying)
    .onAppear {
      input.username = isSimulation ? "simulation" : NSUserName()
      if isSimulation { input.password = "simulation-only" }
      if !isSimulation { focus = input.username.isEmpty ? .username : .password }
    }
    .onChange(of: context.error) { _, error in
      if error == .credentialsRejected {
        if isSimulation { input.password = "simulation-only" }
        if !isSimulation { focus = .password }
      }
    }
    .task { await onCheckHelper() }
    .onDisappear {
      input.clearPassword()
    }
  }

  private var isRetry: Bool {
    context.kind == .retryRecoveryAuthorization
  }

  private var primaryTitle: String {
    if context.helperSwitchedOff && !isSimulation {
      return isRetry
        ? PlainLanguage.authorizeTurnOnAndRetry : PlainLanguage.authorizeTurnOnAndInstall
    }
    return isRetry ? "Authorize Recovery" : "Authorize & install"
  }

  private var errorMessage: String? {
    switch context.error {
    case .credentialsRejected: PlainLanguage.authorizeRejected
    case .helperSetupCancelled: PlainLanguage.authorizeHelperCancelled
    case .helperSwitchedOff: PlainLanguage.authorizeHelperSwitchedOff
    case .helperSetupFailed: PlainLanguage.authorizeHelperFailed
    case .helperBusy: PlainLanguage.authorizeHelperBusy
    case .notAdministrator: PlainLanguage.authorizeNotAdministrator
    case nil: nil
    }
  }

  private func field<Content: View>(
    label: String,
    reason: String?,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(OmarchyTheme.control)
        .foregroundStyle(OmarchyTheme.secondaryText)
      content()
        .controlSize(.large)
        .frame(height: 36)
      if let reason {
        Text(reason)
          .font(OmarchyTheme.detail)
          .foregroundStyle(OmarchyTheme.secondaryText)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)

  }

  private func submit() {
    guard let authorization = input.validated() else {
      return
    }
    input.clearPassword()
    onSubmit(authorization)
  }

  private func cancel() {
    input.clearPassword()
    onCancel()
  }
}
