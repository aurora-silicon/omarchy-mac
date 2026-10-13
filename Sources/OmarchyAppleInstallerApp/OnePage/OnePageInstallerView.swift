import AppKit
import OmarchyAppleInstallerTrustCore
import OmarchyInstallerUXCore
import SwiftUI

/// Version 2 of the installer: one page. The wordmark on top, this Mac in a
/// line, then whatever the moment needs — a download bar, the disk split, an
/// install bar, the Recovery steps — and one primary action underneath.
/// The trust chain and the session are untouched; only the presentation is
/// flattened.
struct OnePageInstallerView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var session: InstallerSession
  @State private var showsShutdownConfirmation = false
  @State private var showsRecoveryRetryConfirmation = false
  /// The last host seen, so the header stays on the page through the phases
  /// that no longer carry it.
  @State private var host: HostDisplay?
  /// The size the owner chose for Omarchy, kept through installation so the
  /// header names it instead of the most Omarchy could take.
  @State private var chosenOmarchyBytes: UInt64?
  /// Which channel this Mac reads. Owned by the scene so the banner always
  /// names the channel the next preparation will actually fetch; `nil` when
  /// the bundle has no release descriptor to fetch from.
  let channel: ReleaseChannel?
  let onChannelAvailability: (Bool) -> Void
  let onSessionAvailable: (InstallerSession) -> Void

  init(
    environment: any InstallerEnvironment,
    channel: ReleaseChannel?,
    onChannelAvailability: @escaping (Bool) -> Void = { _ in },
    onSessionAvailable: @escaping (InstallerSession) -> Void = { _ in }
  ) {
    _session = State(
      initialValue: InstallerSession(
        environment: environment,
        allowsEncryption: InstallerBuildProfile.current.allowsEncryption
      ))
    self.channel = channel
    self.onChannelAvailability = onChannelAvailability
    self.onSessionAvailable = onSessionAvailable
  }

  var body: some View {
    Group {
      if let account = session.recoveryAccount, let target = account.target {
        RecoveryAccountSetupView(volumeName: target.volumeName, session: session)
      } else {
        #if DEBUG
          if session.isSimulation, case .awaitingRecovery = session.phase {
            RecoveryAccountSetupView(volumeName: "Omarchy")
          } else {
            installerPage
          }
        #else
          installerPage
        #endif
      }
    }
    .foregroundStyle(OmarchyTheme.text)
    .background(OmarchyTheme.window)
    .onChange(of: session.canChangeChannel, initial: true) { _, available in
      onChannelAvailability(available)
    }
    .task {
      onSessionAvailable(session)
      await recheck()
    }
    .onChange(of: channel) { _, _ in
      // Switching channel discards anything already planned: the new channel
      // may name a different release entirely.
      Task { await recheck() }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        session.refreshHelperStatus()
      }
    }
    .onChange(of: session.phase, initial: true) { _, phase in
      remember(phase)
      // One page has no "everything is ready" stop: go straight to the plan.
      if case .planPrepared = phase {
        session.continueToPlanReview()
      }
    }
    .sheet(isPresented: credentialSheetBinding) {
      if let context = session.credentialSheet.context {
        CredentialSheet(
          context: context,
          isSimulation: session.isSimulation,
          approvedSize: approvedSize,
          onCancel: { session.dismissCredentials() },
          onSubmit: { authorization in
            Task { await session.submit(authorization) }
          },
          onCheckHelper: { await session.checkWhetherHelperIsSwitchedOff() }
        )
      }
    }
    .sheet(isPresented: $showsShutdownConfirmation) {
      ConfirmationSheet(
        title: PlainLanguage.shutdownConfirmationTitle,
        message: PlainLanguage.shutdownConfirmationBody,
        action: PlainLanguage.shutdownConfirmationAction,
        onConfirm: {
          showsShutdownConfirmation = false
          session.shutDown()
        },
        onCancel: { showsShutdownConfirmation = false }
      )
    }
    .sheet(isPresented: $showsRecoveryRetryConfirmation) {
      ConfirmationSheet(
        title: PlainLanguage.recoveryRetryConfirmationTitle,
        message: PlainLanguage.recoveryRetryConfirmationBody,
        action: PlainLanguage.recoveryRetryConfirmationAction,
        onConfirm: {
          showsRecoveryRetryConfirmation = false
          session.presentRecoveryRetryCredentials()
        },
        onCancel: { showsRecoveryRetryConfirmation = false }
      )
    }
  }

  private var installerPage: some View {
    InstallerPageLayout {
      header
    } content: {
      VStack(alignment: .leading, spacing: 18) { stage }
    } actions: {
      HStack(spacing: 16) { actions }
    }
  }

  // MARK: Header — this Mac in one line

  /// Inspects the Mac, then re-reads what each channel offers it.
  private func recheck() async {
    await session.inspect()
    await session.refreshChannelAvailability()
  }

  @ViewBuilder
  private var header: some View {
    if let host {
      HStack(spacing: 12) {
        Text(host.header(chosenOmarchyBytes: chosenOmarchyBytes))
          .font(OmarchyTheme.eyebrow)
          .textCase(.uppercase)
          .foregroundStyle(OmarchyTheme.accent)
        if let supported = session.modelSupported {
          StatusBadge(
            text: supported ? PlainLanguage.supportedBadge : PlainLanguage.blockedBadge,
            kind: supported ? .ok : .blocked)
        }
        if let channel {
          StatusBadge(text: PlainLanguage.badge(for: channel), kind: .ok)
        }
      }
      .lineLimit(1)
    } else {
      Text(PlainLanguage.inspectingHeadline)
        .font(OmarchyTheme.eyebrow)
        .textCase(.uppercase)
        .foregroundStyle(OmarchyTheme.accent)
    }
  }

  // MARK: The middle of the page

  @ViewBuilder
  private var stage: some View {
    switch session.phase {
    case .inspecting:
      statusPanel(title: PlainLanguage.inspectingSubheadline)

    case .unsupported(let failure):
      messagePanel(
        headline: failure.headline,
        detail: failure.plainDetail,
        remedy: failure.remedy,
        technical: failure.technicalDetail,
        isError: false
      )

    case .welcome:
      Text(PlainLanguage.checkSubheadline)
        .font(OmarchyTheme.body)
        .foregroundStyle(OmarchyTheme.secondaryText)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)

    case .existingInstallRefused:
      existingInstallRefusedPanel()

    case .preparingPlan(let update), .planPrepared(_, let update):
      DownloadPanel(update: update)

    case .planReview(let plan, let acknowledged):
      DiskSplitPanel(
        plan: plan,
        editable: plan.isResizable,
        isBusy: session.isBusy,
        onSizeChosen: { bytes in
          chosenOmarchyBytes = bytes
          session.setAcknowledged(false)
          Task { await session.replan(omarchyBytes: bytes) }
        },
        onEditingChange: { session.setSizeEditing($0) }
      )
      .id(session.planRevision)
      PrefetchStrip(
        state: session.prefetchState,
        onRetry: session.canRetryPrefetch ? { session.retryPrefetch() } : nil
      )
      if session.allowsEncryption {
        EncryptDiskToggle(
          isOn: session.encryptLinuxDisk,
          enabled: !session.isBusy && !session.isEditingSize,
          onChange: { session.setEncryptLinuxDisk($0) }
        )
      } else {
        Text("Private M3 test: Linux will be installed without disk encryption.")
          .font(OmarchyTheme.body).foregroundStyle(OmarchyTheme.caution)
      }
      if let notice = session.allocationNotice {
        Text(notice).font(OmarchyTheme.body).foregroundStyle(OmarchyTheme.caution)
      }
      acknowledgement(acknowledged, resizesMacOS: plan.fixedMacOSBytes == nil)

    case .awaitingInstall(let plan, let helper, _):
      DiskSplitPanel(plan: plan, editable: false, isBusy: false, onSizeChosen: { _ in })
      PrefetchStrip(
        state: session.prefetchState,
        onRetry: session.canRetryPrefetch ? { session.retryPrefetch() } : nil
      )
      if session.allowsEncryption {
        EncryptDiskToggle(
          isOn: session.encryptLinuxDisk,
          enabled: false,
          onChange: { _ in }
        )
      } else {
        Text("Private M3 test: Linux will be installed without disk encryption.")
          .font(OmarchyTheme.body).foregroundStyle(OmarchyTheme.caution)
      }
      if !helper.isReady {
        helperNote
      }

    case .installing(let progress):
      InstallPanel(progress: progress)

    case .awaitingRecovery(let handoff):
      recoveryPanel(handoff)

    case .done(let completion):
      donePanel(completion)

    case .failed(let failure):
      messagePanel(
        headline: failure.headline,
        detail: failure.plainDetail,
        remedy: failure.remedy,
        technical: failure.technicalDetail,
        isError: true
      )
    }
  }

  // MARK: The one row of buttons

  @ViewBuilder
  private var actions: some View {
    switch session.phase {
    case .inspecting, .preparingPlan, .planPrepared:
      EmptyView()

    case .unsupported:
      Button(PlainLanguage.checkAgain) { Task { await recheck() } }
        .omarchySecondaryButton()
        .disabled(session.isBusy)

    case .welcome:
      Button(PlainLanguage.checkContinue) { Task { await session.continueToPlan() } }
        .omarchyPrimaryButton()
        .disabled(session.isBusy)
        .keyboardShortcut(.defaultAction)

    case .existingInstallRefused:
      Button(PlainLanguage.closeInstaller) { NSApplication.shared.terminate(nil) }
        .omarchyPrimaryButton()
        .keyboardShortcut(.defaultAction)

    case .planReview(_, let acknowledged):
      Button(PlainLanguage.planInstall) {
        // Approve the exact plan and go straight to the password. If the
        // helper is not ready the page stays here and says so.
        session.approve()
        if session.canStartInstallation {
          session.presentInstallCredentials()
        }
      }
      .omarchyPrimaryButton()
      .disabled(
        !acknowledged || session.isBusy || session.isEditingSize
          || session.prefetchState != .verified
      )
      .keyboardShortcut(.defaultAction)

    case .awaitingInstall:
      Button("Change size") { session.editPlan() }
        .omarchySecondaryButton()
        .disabled(!session.canEditPlan)
      Button(PlainLanguage.planInstall) { session.presentInstallCredentials() }
        .omarchyPrimaryButton()
        .disabled(!session.canStartInstallation)
        .keyboardShortcut(.defaultAction)

    case .installing:
      Text(PlainLanguage.installWarning)
        .font(OmarchyTheme.detail.weight(.medium))
        .foregroundStyle(OmarchyTheme.accent)

    case .awaitingRecovery:
      if !session.isSimulation {
        Button(PlainLanguage.recoveryShutDown) { showsShutdownConfirmation = true }
          .omarchyPrimaryButton()
          .keyboardShortcut(.defaultAction)
      }

    case .done:
      Button("Close") { NSApplication.shared.terminate(nil) }
        .omarchySecondaryButton()

    case .failed(let failure):
      if session.canInspect {
        Button("Check again") { Task { await recheck() } }
          .omarchySecondaryButton()
      }
      if failure.retryRecoveryAvailable {
        Button(PlainLanguage.retry) { showsRecoveryRetryConfirmation = true }
          .omarchyPrimaryButton()
          .disabled(!session.canRetryRecoveryAuthorization)
          .keyboardShortcut(.defaultAction)
      } else if failure.replanAvailable {
        Button(PlainLanguage.replanAction) {
          Task { await session.replanAfterEngineRefusal() }
        }
        .omarchyPrimaryButton()
        .disabled(session.isBusy)
        .keyboardShortcut(.defaultAction)
      } else if let url = failure.actionURL, let title = failure.actionTitle {
        Button(title) {
          if !session.isSimulation { NSWorkspace.shared.open(url) }
        }
        .disabled(session.isSimulation)
        .omarchyPrimaryButton()
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  // MARK: Pieces

  private func statusPanel(title: String) -> some View {
    Panel {
      VStack(alignment: .leading, spacing: 12) {
        Text(title)
          .font(OmarchyTheme.heading)
          .foregroundStyle(OmarchyTheme.secondaryText)
        ProgressTrack(fraction: nil, height: 14)
      }
      .padding(.vertical, 4)
    }
  }

  private func messagePanel(
    headline: String, detail: String, remedy: String?, technical: String?, isError: Bool
  ) -> some View {
    Panel {
      VStack(alignment: .leading, spacing: 8) {
        Text(headline)
          .font(OmarchyTheme.heading)
          .foregroundStyle(isError ? OmarchyTheme.danger : OmarchyTheme.text)
        Text(detail)
          .font(OmarchyTheme.body)
          .foregroundStyle(OmarchyTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        if let remedy {
          Text(remedy)
            .font(OmarchyTheme.body)
            .foregroundStyle(OmarchyTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
        }
        if let technical {
          DisclosureGroup("Technical details") {
            TechnicalDetailText(text: technical)
            Button("Copy error details") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(technical, forType: .string)
            }
          }.padding(.top, 4)
        }
        if session.hasExecutionStarted {
          Text(
            "This installation can’t be started again yet. Review the installation record below, and keep this Mac plugged in."
          )
          .font(OmarchyTheme.body)
          DisclosureGroup("Last verified steps") {
            if session.journal.feed.isEmpty {
              Text(
                "No completed disk step was confirmed. Disk changes may still have started."
              )
            }
            Button("Copy installation record") {
              let record = ([headline, detail, technical ?? ""] + session.journal.feed.map(\.text))
                .joined(separator: "\n")
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(record, forType: .string)
            }
            ForEach(session.journal.feed) { line in
              Text(line.text).font(OmarchyTheme.technical).textSelection(.enabled)
            }
          }
        }
      }
      .padding(.vertical, 2)
    }
  }

  private func existingInstallRefusedPanel() -> some View {
    Panel {
      Text(PlainLanguage.existingInstallHeadline)
        .font(OmarchyTheme.heading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
      Text(
        "If you’d like to remove Omarchy and return its space to macOS, select Installation → Remove Omarchy from the menu bar."
      )
      .font(OmarchyTheme.body)
      .foregroundStyle(OmarchyTheme.secondaryText)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The tick and its text. Both are inert while a re-plan runs so a tick
  /// cannot land between the drag and the new plan.
  private func acknowledgement(_ acknowledged: Bool, resizesMacOS: Bool) -> some View {
    let text = PlainLanguage.planAcknowledgement(resizesMacOS: resizesMacOS)
    return HStack(alignment: .center, spacing: 12) {
      Toggle(
        "",
        isOn: Binding(get: { acknowledged }, set: { session.setAcknowledged($0) })
      )
      .labelsHidden()
      .toggleStyle(.checkbox)
      .controlSize(.large)
      .tint(OmarchyTheme.accent)
      .accessibilityLabel(text)
      Text(text)
        .font(OmarchyTheme.heading)
        .foregroundStyle(OmarchyTheme.accent)
        .fixedSize(horizontal: false, vertical: true)
        .onTapGesture { session.setAcknowledged(!acknowledged) }
      Spacer(minLength: 0)
    }
    .disabled(session.isBusy || session.isEditingSize)
    .padding(.horizontal, 4)
    .padding(.top, 4)
  }

  private var helperNote: some View {
    HStack(spacing: 10) {
      Image(systemName: "lock.shield")
        .foregroundStyle(OmarchyTheme.caution)
      Text(PlainLanguage.helperNotInstalled)
        .omarchyHelpText()
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 4)
  }

  private func recoveryPanel(_ handoff: HandoffDisplay) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(handoff.headline)
        .font(OmarchyTheme.heading)
        .padding(.bottom, 4)
      if let warning = handoff.warning {
        Text(warning)
          .font(OmarchyTheme.body)
          .foregroundStyle(OmarchyTheme.caution)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(handoff.steps) { step in
        RecoveryStepRow(step: step)
      }
      if let message = session.shutdownMessage {
        Text(message).font(OmarchyTheme.body).foregroundStyle(OmarchyTheme.caution)
      }
    }
  }

  private func donePanel(_ completion: CompletionDisplay) -> some View {
    Panel {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          Image(systemName: "checkmark.circle.fill")
            .font(OmarchyTheme.heading)
            .imageScale(.large)
            .foregroundStyle(OmarchyTheme.accent)
          Text(completion.headline)
            .font(OmarchyTheme.heading)
        }
        Text(completion.subheadline)
          .font(OmarchyTheme.body)
          .foregroundStyle(OmarchyTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        FactGrid(rows: completion.verified, labelWidth: 118)
          .padding(.top, 6)
      }
    }
  }

  // MARK: Plumbing

  private var approvedSize: String? {
    guard case .awaitingInstall(let plan, _, _) = session.phase else { return nil }
    return PlainLanguage.bytes(plan.omarchyBytes)
  }

  private var credentialSheetBinding: Binding<Bool> {
    Binding(
      get: { session.credentialSheet.context != nil },
      set: { presented in
        if !presented {
          session.dismissCredentials()
        }
      }
    )
  }

  private func remember(_ phase: InstallerSessionPhase) {
    switch phase {
    case .welcome(let seen):
      host = seen
      chosenOmarchyBytes = nil
    case .existingInstallRefused(let seen):
      host = seen
      chosenOmarchyBytes = nil
    case .unsupported(let failure):
      host = failure.device
      chosenOmarchyBytes = nil
    case .inspecting:
      host = nil
      chosenOmarchyBytes = nil
    case .planReview(let plan, _) where chosenOmarchyBytes != nil:
      // The engine may round a chosen size; name the size it planned.
      chosenOmarchyBytes = plan.omarchyBytes
    case .awaitingInstall(let plan, _, _):
      chosenOmarchyBytes = plan.omarchyBytes
    default:
      break
    }
  }
}

// MARK: - Prefetch strip and encryption

private struct PrefetchStrip: View {
  let state: PayloadPrefetchState
  var onRetry: (() -> Void)?

  var body: some View {
    if showsStrip {
      Panel {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(PlainLanguage.prefetchTitle(for: state))
              .font(OmarchyTheme.heading)
            Spacer(minLength: 8)
            if let accessory {
              Text(accessory)
                .font(OmarchyTheme.detail)
                .foregroundStyle(OmarchyTheme.secondaryText)
            }
          }
          if case .failed(let reason) = state {
            Text(reason)
              .omarchyHelpText()
              .textSelection(.enabled)
            if let onRetry {
              Button(PlainLanguage.prefetchRetry, action: onRetry)
            }
          } else {
            ProgressTrack(fraction: fraction, height: 10)
          }
        }
        .padding(.vertical, 2)
      }
    }
  }

  private var showsStrip: Bool {
    switch state {
    case .verified, .idle: false
    default: true
    }
  }

  private var fraction: Double? {
    switch state {
    case .downloading(let completed, let total), .paused(let completed, let total):
      total > 0 ? Double(completed) / Double(total) : nil
    case .verifying:
      1
    default:
      nil
    }
  }

  private var accessory: String? {
    switch state {
    case .downloading(let completed, let total), .paused(let completed, let total):
      total > 0
        ? "\(PlainLanguage.bytes(completed)) of \(PlainLanguage.bytes(total))" : nil
    default:
      nil
    }
  }
}

private struct EncryptDiskToggle: View {
  let isOn: Bool
  let enabled: Bool
  let onChange: (Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(
        PlainLanguage.encryptLinuxDiskTitle,
        isOn: Binding(
          get: { isOn },
          set: { value in onChange(value) }
        )
      )
      .toggleStyle(.checkbox)
      .controlSize(.large)
      .tint(OmarchyTheme.accent)
      .disabled(!enabled)
      // One help paragraph: the password, and that nothing else unlocks the disk.
      Text(PlainLanguage.encryptLinuxDiskPassword + " " + PlainLanguage.encryptLinuxDiskNoRecovery)
        .omarchyHelpText()
    }
    .padding(.horizontal, 4)
    .padding(.top, 4)
  }
}

// MARK: - The download bar

/// One bar for the OS package download; later stages (engine checks,
/// planning) keep the last position instead of resetting.
private struct DownloadPanel: View {
  let update: AssetProgressUpdate

  @State private var lastCompleted: UInt64 = 0
  @State private var lastTotal: UInt64 = 0

  private var package: AssetProgressRow? {
    update.rows.first { $0.role == "payload" } ?? update.rows.first
  }

  var body: some View {
    Panel {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text(title)
            .font(OmarchyTheme.heading)
          Spacer(minLength: 8)
          if let accessory {
            Text(accessory)
              .font(OmarchyTheme.detail)
              .foregroundStyle(OmarchyTheme.secondaryText)
          }
        }
        ProgressTrack(fraction: fraction, height: 18)
      }
      .padding(.vertical, 4)
    }
    .onChange(of: update, initial: true) { _, _ in
      if let package, package.totalBytes > 0 {
        lastCompleted = package.bytesCompleted
        lastTotal = package.totalBytes
      }
    }
  }

  private var title: String {
    update.stage == .downloading
      ? PlainLanguage.downloadingPackagesTitle
      : PlainLanguage.preparingStageTitle(update.stage)
  }

  private var fraction: Double? {
    if update.stage == .downloading, let package, package.totalBytes > 0 {
      return Double(package.bytesCompleted) / Double(package.totalBytes)
    }
    guard lastTotal > 0 else {
      return nil
    }
    return Double(lastCompleted) / Double(lastTotal)
  }

  private var accessory: String? {
    let total = (package?.totalBytes ?? 0) > 0 ? package!.totalBytes : lastTotal
    guard total > 0 else {
      return nil
    }
    let completed = (package?.totalBytes ?? 0) > 0 ? package!.bytesCompleted : lastCompleted
    return "\(PlainLanguage.bytes(completed)) of \(PlainLanguage.bytes(total))"
  }
}

// MARK: - The disk split

/// The disk bar with the draggable divider. Letting go on a new whole-GB
/// size re-plans; the chosen size stays on screen until the new plan lands.
private struct DiskSplitPanel: View {
  let plan: PlanDisplay
  let editable: Bool
  let isBusy: Bool
  let onSizeChosen: (UInt64) -> Void
  var onEditingChange: (Bool) -> Void = { _ in }

  @State private var exploredOmarchyGB: Double?
  @State private var sizeInput = DiskSizeInput()
  @FocusState private var sizeFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Panel {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .firstTextBaseline) {
            Text(plan.fixedMacOSBytes == nil ? "macOS" : "macOS + free space")
              .font(OmarchyTheme.heading)
              .foregroundStyle(OmarchyTheme.accent)
            Spacer(minLength: 8)
            Text("Omarchy")
              .font(OmarchyTheme.heading)
              .foregroundStyle(OmarchyTheme.accent)
          }
          DiskBar(
            macOSBytes: plan.macOSBytes(for: displayedOmarchyBytes),
            omarchyBytes: displayedOmarchyBytes,
            unallocatedBytes: plan.unallocatedBytes(for: displayedOmarchyBytes),
            macOSSpaceCaution: plan.macOSSpaceCaution(for: displayedOmarchyBytes),
            onAdjustOmarchyFraction: editable ? { adjust($0) } : nil,
            onCommitOmarchyFraction: editable ? { commit($0) } : nil,
            isFrozen: isBusy || sizeInput.isEditing
          )
          .transaction { $0.animation = nil }
          if editable {
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 8) {
                Text("Space for Omarchy").font(OmarchyTheme.body)
                TextField(
                  "Size",
                  text: Binding(
                    get: {
                      sizeInput.isEditing ? sizeInput.text : sizeInput.display(plan.omarchyBytes)
                    },
                    set: { value in
                      beginSizeEdit()
                      sizeInput.text = value
                    }
                  )
                )
                .textFieldStyle(.roundedBorder)
                .font(OmarchyTheme.control)
                .frame(width: 62, height: 28)
                .focused($sizeFocused)
                .onTapGesture {
                  beginSizeEdit()
                  sizeFocused = true
                }
                .accessibilityLabel("Omarchy size in gigabytes")
                .onSubmit(applySize)
                .onExitCommand(perform: cancelSize)
                Text("GB").font(OmarchyTheme.detail)
                if sizeInput.isEditing {
                  Button(action: applySize) {
                    Image(systemName: "checkmark")
                      .font(OmarchyTheme.control)
                      .frame(width: 28, height: 28)
                  }
                  .buttonStyle(SizeEditButtonStyle(tint: OmarchyTheme.success))
                  .accessibilityLabel("Apply size")
                  .help("Apply size (Return)")
                  .disabled(sizeInput.requestedBytes == nil)
                  Button(action: cancelSize) {
                    Image(systemName: "xmark")
                      .font(OmarchyTheme.control)
                      .frame(width: 28, height: 28)
                  }
                  .buttonStyle(SizeEditButtonStyle(tint: OmarchyTheme.danger))
                  .accessibilityLabel("Cancel size edit")
                  .help("Cancel size edit (Escape)")
                }
                Spacer(minLength: 0)
              }
              if let message = sizeInput.validationMessage {
                Text(message).font(OmarchyTheme.detail).foregroundStyle(OmarchyTheme.danger)
              }
            }
            .disabled(isBusy)

          }
          if plan.fixedMacOSBytes != nil {
            Text(
              "\(PlainLanguage.bytes(plan.unallocatedBytes(for: displayedOmarchyBytes))) remains unallocated. macOS keeps its current size."
            )
            .omarchyHelpText()
          }
          Text("Omarchy will use the space selected above.")
            .omarchyHelpText()
            .padding(.trailing, 28)
        }
        .padding(.vertical, 4)
      }
      .overlay(alignment: .bottomTrailing) {
        if isBusy {
          ProgressView()
            .controlSize(.small)
            .frame(width: 16, height: 16)
            .padding(.trailing, 14)
            .padding(.bottom, 16)
            .accessibilityLabel(PlainLanguage.replanning)
            .help(PlainLanguage.replanning)
        }
      }
      ForEach(plan.spaceCautions(for: displayedOmarchyBytes), id: \.self) { caution in
        Text(caution).font(OmarchyTheme.body).foregroundStyle(OmarchyTheme.caution)
      }
    }
    .onChange(of: plan.omarchyBytes) { _, _ in
      exploredOmarchyGB = nil
    }
  }

  private var displayedOmarchyBytes: UInt64 {
    guard let exploredOmarchyGB else {
      return plan.omarchyBytes
    }
    return UInt64(exploredOmarchyGB * 1_000_000_000)
  }

  private func beginSizeEdit() {
    guard !isBusy && editable else { return }
    sizeInput.begin(
      bytes: plan.omarchyBytes, minimum: plan.minimumBytes, maximum: plan.maximumBytes)
    onEditingChange(true)
  }

  private func applySize() {
    guard !isBusy, let chosen = sizeInput.apply() else { return }
    sizeFocused = false
    onEditingChange(false)
    if chosen != plan.omarchyBytes { onSizeChosen(chosen) }
  }

  private func cancelSize() {
    sizeInput.cancel()
    sizeFocused = false
    onEditingChange(false)
  }

  private func adjust(_ fraction: Double) {
    let requested = Double(plan.diskTotalBytes) * min(1, max(0, fraction))
    let chosen = min(Double(plan.maximumBytes), max(Double(plan.minimumBytes), requested))
    exploredOmarchyGB = chosen / 1_000_000_000
  }

  private func commit(_ fraction: Double) {
    adjust(fraction)
    let rounded = (Double(displayedOmarchyBytes) / 1_000_000_000).rounded() * 1_000_000_000
    let chosen = min(plan.maximumBytes, max(plan.minimumBytes, UInt64(rounded)))
    if chosen != plan.omarchyBytes {
      onSizeChosen(chosen)
    } else {
      exploredOmarchyGB = nil
    }
  }
}

// MARK: - The install bar

/// Stage count and verified activity describe progress without inventing a
/// percentage for operations whose duration is unknown.
private struct InstallPanel: View {
  let progress: InstallProgressDisplay
  @State private var estimate = InstallationProgressEstimate(
    expectedSeconds: InstallationTimingHistory.expectedSeconds)

  private var stageLabel: String {
    let index = progress.stageIndex
    if progress.stageLabels.indices.contains(index) {
      return progress.phaseTitle
    }
    return progress.phaseTitle
  }

  var body: some View {
    Panel {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text(stageLabel)
            .font(OmarchyTheme.heading)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 8)
          TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
            Text(elapsed(at: context.date))
              .font(OmarchyTheme.detail)
              .foregroundStyle(OmarchyTheme.secondaryText)
          }
          Text(
            "Step \(min(progress.stageIndex + 1, progress.stageLabels.count)) of \(progress.stageLabels.count)"
          )
          .font(OmarchyTheme.body)
        }
        TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
          let elapsed = max(0, context.date.timeIntervalSince(progress.startedAt))
          VStack(alignment: .leading, spacing: 6) {
            ProgressTrack(fraction: estimate.fraction, height: 18)
            HStack {
              Text("Estimated progress · \(Int(estimate.fraction * 100))%")
              Spacer()
              if let minutes = estimate.remainingMinutes(elapsed: elapsed) {
                Text("About \(minutes) min remaining")
              } else {
                Text("Taking longer than estimated")
              }
            }
            .font(OmarchyTheme.detail)
            .foregroundStyle(OmarchyTheme.secondaryText)
          }
          .onChange(of: context.date, initial: true) { _, date in
            estimate.update(
              elapsed: date.timeIntervalSince(progress.startedAt),
              completedStages: progress.stageFractions.filter { $0 >= 1 }.count)
          }
        }
        DisclosureGroup("View activity") {
          ForEach(progress.feed) { line in
            Text(line.text).font(OmarchyTheme.technical).textSelection(.enabled)
          }
        }
        if progress.degraded {
          Text(PlainLanguage.installDegraded)
            .omarchyHelpText()
        }
      }
      .padding(.vertical, 4)
    }
  }

  private func elapsed(at date: Date) -> String {
    let seconds = max(0, Int(date.timeIntervalSince(progress.startedAt)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

/// Quiet, keyboard-sized actions that share the editor's terminal palette.
private struct SizeEditButtonStyle: ButtonStyle {
  let tint: Color
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    SizeEditButtonBody(configuration: configuration, tint: tint, isEnabled: isEnabled)
  }

  private struct SizeEditButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    let isEnabled: Bool
    @State private var isHovered = false

    var body: some View {
      configuration.label
        .foregroundStyle(isEnabled ? tint : OmarchyTheme.secondaryText.opacity(0.4))
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(
              tint.opacity(
                isEnabled && configuration.isPressed ? 0.20 : isEnabled && isHovered ? 0.10 : 0))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 4)
            .strokeBorder(
              isEnabled && isHovered ? tint.opacity(0.35) : OmarchyTheme.separator.opacity(0.5),
              lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
  }
}
