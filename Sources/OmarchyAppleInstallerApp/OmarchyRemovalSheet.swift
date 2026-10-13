import AppKit
import OmarchyAppleInstallerTrustCore
import OmarchyInstallerUXCore
import SwiftUI

struct OmarchyRemovalSheet: View {
  let isSimulation: Bool
  let onBusyChanged: (Bool) -> Void
  let onClose: () -> Void
  let onRequiresReview: () -> Void
  let simulationScenario: String?

  @State private var ticket: OmarchyRemovalTicket?
  @State private var phrase = ""
  @State private var username = NSUserName()
  @State private var password = ""
  @State private var busy = false
  @State private var submitted = false
  @State private var completed = false
  @State private var message = "Checking for an existing Omarchy installation…"
  @State private var client: AuthenticatedEngineXPCSubmitter?
  /// No helper is installed yet: the account is asked for first, to set it
  /// up, and the same password then approves the removal.
  @State private var needsAccountFirst = false
  /// The person switched the helper off; the account first turns it back on.
  @State private var reenablingHelper = false
  @State private var contentHeight: CGFloat = 0
  @State private var footerHeight: CGFloat = 0
  @State private var measuredHeightCap: CGFloat?
  private var fixedHeightCap: CGFloat?
  private var preloaded = false
  private var onControlFrame: ((String, CGRect) -> Void)?
  #if DEBUG
    @State private var scenario = RemovalPreviewScenario.success
  #endif

  init(
    isSimulation: Bool, onBusyChanged: @escaping (Bool) -> Void,
    onClose: @escaping () -> Void, onRequiresReview: @escaping () -> Void,
    simulationScenario: String? = nil
  ) {
    self.isSimulation = isSimulation
    self.simulationScenario = simulationScenario
    #if DEBUG
      if let simulationScenario, let selected = RemovalPreviewScenario(rawValue: simulationScenario)
      {
        _scenario = State(initialValue: selected)
      }
    #endif
    self.onBusyChanged = onBusyChanged
    self.onClose = onClose
    self.onRequiresReview = onRequiresReview
    _measuredHeightCap = State(
      initialValue: NSApp?.mainWindow.flatMap(RemovalSheetLayout.heightCap(for:)))
  }

  #if DEBUG
    init(
      previewScenario: RemovalPreviewScenario, heightCap: CGFloat?,
      showsAccountFields: Bool = false,
      onControlFrame: ((String, CGRect) -> Void)? = nil
    ) {
      self.init(
        isSimulation: !showsAccountFields, onBusyChanged: { _ in }, onClose: {},
        onRequiresReview: {})
      let (ticket, message) = previewScenario.previewTicket
      _scenario = State(initialValue: previewScenario)
      _ticket = State(initialValue: ticket)
      _message = State(initialValue: message)
      fixedHeightCap = heightCap
      preloaded = true
      self.onControlFrame = onControlFrame
    }
  #endif

  private var canRemove: Bool {
    ticket != nil && !busy && !submitted && phrase == ticket?.confirmation
      && (isSimulation || (!username.isEmpty && !password.isEmpty))
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView(.vertical) {
        scrollingContent
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            contentHeight = $0
          }
      }
      .contentMargins(.bottom, bodyScrolls ? 18 : 0, for: .scrollContent)
      .frame(height: bodyHeight)
      .scrollBounceBehavior(.basedOnSize)
      footer
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          footerHeight = $0
        }
        .overlay(alignment: .top) { if bodyScrolls { Divider() } }
    }
    .frame(width: 520)
    .coordinateSpace(.named(RemovalSheetLayout.coordinateSpace))
    .omarchyTypography()
    .foregroundStyle(OmarchyTheme.text)
    .background(OmarchyTheme.window)
    .background {
      if fixedHeightCap == nil {
        RemovalSheetHeightCapReader { measuredHeightCap = $0 }
      }
    }
    .interactiveDismissDisabled(busy)
    .task { if !preloaded { await prepare() } }
    .onDisappear { password = "" }
    .onChange(of: busy) { _, value in onBusyChanged(value) }
    .onChange(of: simulationScenario) { _, value in
      #if DEBUG
        if !busy, let value, let selected = RemovalPreviewScenario(rawValue: value) {
          scenario = selected
          Task { await prepare() }
        }
      #endif
    }
  }

  private var heightCap: CGFloat {
    fixedHeightCap ?? measuredHeightCap ?? RemovalSheetLayout.fallbackHeightCap()
  }

  private var bodyHeight: CGFloat {
    RemovalSheetLayout.bodyHeight(
      content: contentHeight, footer: footerHeight, cap: heightCap)
  }

  private var bodyScrolls: Bool { contentHeight > bodyHeight + 0.5 }

  private var scrollingContent: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(heading)
        .font(OmarchyTheme.title)
        .foregroundStyle(OmarchyTheme.accent)

      if reenablingHelper && needsAccountFirst && !busy {
        // The same caution callout as the authorize sheet, so a switched-off
        // helper is not mistaken for the ordinary first-time account step.
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "switch.2")
          Text(message)
        }
        .font(OmarchyTheme.body)
        .foregroundStyle(OmarchyTheme.caution)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("removal-message")
      } else {
        Text(message)
          .font(OmarchyTheme.body)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("removal-message")
      }
      if let ticket, !submitted {
        VStack(alignment: .leading, spacing: 10) {
          if let step = ticket.startupDisk {
            VStack(alignment: .leading, spacing: 6) {
              Text("First").foregroundStyle(OmarchyTheme.secondaryText)
              VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                Text(step.detail)
                  .font(OmarchyTheme.detail)
                  .foregroundStyle(OmarchyTheme.secondaryText)
              }
              .accessibilityElement(children: .combine)
              .accessibilityIdentifier("removal-startup-disk")
            }
            .font(OmarchyTheme.body)
          }
          if !ticket.deletions.isEmpty {
            planSection("Deleted", items: ticket.deletions)
          }
          summaryRow("Space returned to macOS", value: PlainLanguage.bytes(ticket.reclaimBytes))
          summaryRow("macOS after removal", value: PlainLanguage.bytes(ticket.macOSBytesAfter))
          planSection("Stays as it is", items: ticket.kept)
        }
        .padding(14)
        .background(OmarchyTheme.card, in: RoundedRectangle(cornerRadius: 8))
        ForEach(ticket.notes, id: \.self) { note in
          Text(note)
            .font(OmarchyTheme.body)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(
          ticket.kind == .freeSpace
            ? "Your macOS files stay as they are. This can’t be undone."
            : "Your macOS files stay as they are. Everything in the deleted partitions is lost. Removal can’t be undone."
        )
        .font(OmarchyTheme.body)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding([.horizontal, .top], 26)
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 18) {
      if needsAccountFirst && ticket == nil && !isSimulation {
        accountFields
      }
      if let ticket, !submitted {
        VStack(alignment: .leading, spacing: 7) {
          Text("Type this to confirm:")
            .foregroundStyle(OmarchyTheme.secondaryText)
          Text(ticket.confirmation)
            .font(OmarchyTheme.heading)
            .textSelection(.enabled)
          TextField("Confirmation phrase", text: $phrase)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .accessibilityIdentifier("removal-confirmation")
            .reportsFrame("removal-confirmation", to: onControlFrame)
        }
        .font(OmarchyTheme.body)
        if !isSimulation {
          accountFields
        }
      }
      if busy {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text(progressText)
            .font(OmarchyTheme.detail)
        }
        .foregroundStyle(OmarchyTheme.secondaryText)
      }
      HStack(spacing: 12) {
        Spacer()
        Button(submitted || ticket == nil ? "Close" : "Cancel") {
          password = ""
          onClose()
        }
        .omarchySecondaryButton()
        .keyboardShortcut(.cancelAction)
        .focusEffectDisabled()
        .disabled(busy)
        if needsAccountFirst && ticket == nil && !isSimulation {
          if reenablingHelper {
            Button(PlainLanguage.openLoginItems) {
              NSWorkspace.shared.open(PlainLanguage.loginItemsSettingsURL)
            }
            .omarchySecondaryButton()
            .focusEffectDisabled()
          }
          Button(continueTitle) { Task { await setUpHelperThenScan() } }
            .omarchyPrimaryButton()
            .keyboardShortcut(.defaultAction)
            .disabled(busy || username.isEmpty || password.isEmpty)
        }
        if let ticket, !submitted {
          Button(ticket.kind == .freeSpace ? "Return Space" : "Remove Omarchy", role: .destructive)
          { Task { await remove() } }
          .omarchyDangerButton()
          .disabled(!canRemove)
          .accessibilityIdentifier("remove-omarchy")
          .reportsFrame("remove-omarchy", to: onControlFrame)
        }
      }
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 26)
    .padding(.top, 18)
    .padding(.bottom, 26)
  }

  private var continueTitle: String {
    reenablingHelper ? PlainLanguage.removalTurnOnAndContinue : PlainLanguage.removalContinue
  }

  private var progressText: String {
    if submitted { return "Keep your Mac on until removal finishes." }
    return needsAccountFirst ? "Setting up the removal service…" : "Reading the disk layout…"
  }

  private var accountFields: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("macOS administrator account").foregroundStyle(OmarchyTheme.secondaryText)
      TextField("Account name", text: $username)
        .textFieldStyle(.roundedBorder)
        .textContentType(.username)
        .autocorrectionDisabled()
      SecureField("macOS password", text: $password)
        .textFieldStyle(.roundedBorder)
        .textContentType(.password)
        .privacySensitive()
    }
    .font(OmarchyTheme.body)
  }

  private var heading: String {
    if ticket?.kind == .freeSpace { return completed ? "Space returned" : "Return free space" }
    return completed ? "Omarchy removed" : "Remove Omarchy"
  }

  private func planSection(_ title: String, items: [OmarchyRemovalItem]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).foregroundStyle(OmarchyTheme.secondaryText)
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
            Text(item.detail)
              .font(OmarchyTheme.detail)
              .foregroundStyle(OmarchyTheme.secondaryText)
          }
          Spacer()
          Text(PlainLanguage.bytes(item.bytes)).fontWeight(.medium)
        }
      }
    }
    .font(OmarchyTheme.body)
  }

  private func summaryRow(_ label: String, value: String) -> some View {
    HStack {
      Text(label).foregroundStyle(OmarchyTheme.secondaryText)
      Spacer()
      Text(value).fontWeight(.medium)
    }.font(OmarchyTheme.body)
  }

  /// - Parameter keepingAccount: true right after the helper was set up with
  ///   the typed account, which then also approves the removal.
  @MainActor private func prepare(keepingAccount: Bool = false) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    ticket = nil
    phrase = ""
    if !keepingAccount { password = "" }
    submitted = false
    completed = false
    message = "Checking for an existing Omarchy installation…"
    #if DEBUG
      if isSimulation {
        try? await Task.sleep(for: .milliseconds(350))
        if scenario == .none || scenario == .ambiguous || scenario == .helperUnavailable {
          message = scenario.message
        } else {
          (ticket, message) = scenario.previewTicket
        }
        return
      }
    #endif
    if !keepingAccount {
      // An unreadable model counts as blocked: nothing privileged is set up
      // without knowing the Mac is one the installer allows.
      let blocked = (try? AppleSiliconHostInspector().isBlockedModel()) ?? true
      switch RemovalHelperStart(
        helper: await InstallerHelperSetup.probeDisplay(), blockedModel: blocked)
      {
      case .blockedModel:
        message = PlainLanguage.removalBlockedModel
        return
      case .busy:
        message = PlainLanguage.removalServiceBusy
        return
      case .scan:
        break
      case .credentialsFirst:
        needsAccountFirst = true
        message = PlainLanguage.removalCredentialsFirst
        return
      case .switchedOff:
        needsAccountFirst = true
        reenablingHelper = true
        message = PlainLanguage.removalSwitchedOff
        return
      case .unavailable:
        message = PlainLanguage.removalServiceMissing
        return
      }
    }
    do {
      let submitter = try InstallerHelperSetup.submitter()
      client = submitter
      let reply = try await submitter.removal()
      ticket = reply.ticket
      message = reply.message
    } catch {
      message =
        InstallerHelperSetup.canInstall
        ? PlainLanguage.removalServiceNotResponding : PlainLanguage.removalServiceMissing
    }
    // Nothing to confirm, so nothing for the typed password to approve.
    if ticket == nil {
      password = ""
    }
  }

  /// Sets the helper up with the typed account, then scans as usual.
  @MainActor private func setUpHelperThenScan() async {
    guard needsAccountFirst, !busy else { return }
    let authorization: MachineOwnerAuthorization
    do {
      authorization = try MachineOwnerAuthorization(
        username: username, password: Data(password.utf8))
    } catch {
      message = "Enter a valid macOS administrator account and password."
      return
    }
    busy = true
    message = "Setting up the removal service…"
    do {
      try await InstallerHelperSetup.ensure(
        authorization, reenablingSwitchedOff: reenablingHelper)
    } catch {
      busy = false
      password = ""
      message = PlainLanguage.removalHelperSetupMessage(for: error)
      return
    }
    busy = false
    needsAccountFirst = false
    reenablingHelper = false
    await prepare(keepingAccount: true)
  }

  @MainActor private func remove() async {
    guard canRemove, let ticket else { return }
    let authorization: MachineOwnerAuthorization?
    do {
      authorization =
        isSimulation
        ? nil : try MachineOwnerAuthorization(username: username, password: Data(password.utf8))
    } catch {
      message = "Enter a valid macOS administrator account and password."
      return
    }
    password = ""
    busy = true
    submitted = true
    message =
      ticket.startupDisk == nil
      ? "Removing Omarchy, then returning its space to macOS…"
      : "Setting macOS as the startup disk, removing Omarchy, then returning its space to macOS…"
    defer { busy = false }
    #if DEBUG
      if isSimulation {
        try? await Task.sleep(for: .seconds(2))
        if scenario == .disconnected {
          connectionLost()
          return
        }
        completed = [.success, .asahi, .freeSpace, .startupDisk].contains(scenario)
        if [.interrupted, .reclaimFailed, .disconnected].contains(scenario) { onRequiresReview() }
        message = scenario.message
        return
      }
    #endif
    guard let client else {
      submitted = false
      message = PlainLanguage.removalNotStarted
      return
    }
    do {
      let reply = try await client.removal(
        ticket: ticket, confirmation: phrase, authorization: authorization)
      completed = reply.completed
      if reply.requiresReview { onRequiresReview() }
      message = reply.message
    } catch EngineXPCSubmissionError.notSubmitted {
      // Never sent, so nothing started and nothing needs review.
      submitted = false
      message = PlainLanguage.removalNotStarted
    } catch {
      let outcome = RemovalConnectionLoss(
        helperRetired: await RemovalOutcomeProbe.helperRetired(),
        macOSContainerBytes: RemovalOutcomeProbe.macOSContainerBytes(),
        macOSBytesAfter: ticket.macOSBytesAfter, reclaimBytes: ticket.reclaimBytes)
      switch outcome {
      case .completed:
        completed = true
        message = PlainLanguage.removalCompletedWithoutReply(freeSpace: ticket.kind == .freeSpace)
      case .unknown:
        connectionLost()
      }
    }
  }

  private func connectionLost() {
    onRequiresReview()
    message =
      "The connection to the removal service was lost. Removal may still be running. Don’t restart removal or turn off this Mac. Check the removal record before continuing."
  }
}

enum RemovalSheetLayout {
  static let coordinateSpace = "removal-sheet"
  static let screenMargin: CGFloat = 16
  static let minimumHeightCap: CGFloat = 360

  /// A sheet hangs from just below its parent window's title bar, so it can
  /// only grow down to the bottom of the parent screen's visible frame.
  static func heightCap(
    parentFrame: CGRect, titleBarHeight: CGFloat, visibleFrame: CGRect
  ) -> CGFloat {
    let available =
      min(parentFrame.maxY - titleBarHeight, visibleFrame.maxY) - visibleFrame.minY - screenMargin
    return min(max(available, minimumHeightCap), visibleFrame.height).rounded(.down)
  }

  static func bodyHeight(content: CGFloat, footer: CGFloat, cap: CGFloat) -> CGFloat {
    max(min(content, cap - footer), 0)
  }

  @MainActor static func fallbackHeightCap() -> CGFloat {
    guard let visibleFrame = NSScreen.main?.visibleFrame else { return .greatestFiniteMagnitude }
    return max(visibleFrame.height - screenMargin, minimumHeightCap)
  }

  @MainActor static func heightCap(for parent: NSWindow) -> CGFloat? {
    guard let screen = parent.screen ?? NSScreen.main else { return nil }
    return heightCap(
      parentFrame: parent.frame,
      titleBarHeight: parent.frame.height - parent.contentLayoutRect.height,
      visibleFrame: screen.visibleFrame)
  }
}

extension View {
  fileprivate func reportsFrame(_ id: String, to report: ((String, CGRect) -> Void)?) -> some View {
    onGeometryChange(for: CGRect.self) {
      $0.frame(in: .named(RemovalSheetLayout.coordinateSpace))
    } action: {
      report?(id, $0)
    }
  }
}

private struct RemovalSheetHeightCapReader: NSViewRepresentable {
  let onChange: (CGFloat) -> Void

  func makeNSView(context: Context) -> ReaderView {
    let view = ReaderView()
    view.onChange = onChange
    return view
  }

  func updateNSView(_ view: ReaderView, context: Context) {
    view.onChange = onChange
  }

  final class ReaderView: NSView {
    var onChange: ((CGFloat) -> Void)?
    private var lastCap: CGFloat?

    // Selector observers are removed automatically when the view is freed.
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      let center = NotificationCenter.default
      center.removeObserver(self)
      guard window != nil else { return }
      for name in [
        NSWindow.didMoveNotification, NSWindow.didResizeNotification,
        NSWindow.didChangeScreenNotification, NSWindow.didBecomeKeyNotification,
        NSApplication.didChangeScreenParametersNotification,
      ] {
        center.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
      }
      DispatchQueue.main.async { [weak self] in self?.update() }
    }

    @objc private func changed(_ note: Notification) {
      guard let changed = note.object as? NSWindow else { return update() }
      if changed === window || changed === window?.sheetParent { update() }
    }

    private func update() {
      guard let parent = window?.sheetParent ?? NSApp?.mainWindow, parent !== window,
        let cap = RemovalSheetLayout.heightCap(for: parent), cap != lastCap
      else { return }
      lastCap = cap
      onChange?(cap)
    }
  }
}

#if DEBUG
  enum RemovalPreviewScenario: String, CaseIterable {
    case success = "Complete removal"
    case asahi = "Older omarchy-mac installation"
    case startupDisk = "Starts up from Omarchy"
    case startupFailed = "Startup disk not changed"
    case freeSpace = "Free space only"
    case none = "No installation"
    case ambiguous = "Unfamiliar or partial layout"
    case helperUnavailable = "Helper unavailable"
    case credentials = "Incorrect password"
    case changed = "Disk changed since confirmation"
    case interrupted = "Deletion interrupted"
    case reclaimFailed = "macOS resize failed"
    case disconnected = "Connection lost"

    /// Each preview is one consistent disk: members sit between macOS and
    /// Recovery, so macOS after removal is macOS plus everything removed.
    /// `success` is the M1 Pro lab Mac's converged install (2026-09-28).
    var previewTicket: (OmarchyRemovalTicket, String) {
      func kept(macOS: UInt64, after: UInt64, recovery: String) -> [OmarchyRemovalItem] {
        [
          OmarchyRemovalItem(
            title: "macOS “Macintosh HD”",
            detail: "disk0s2 · grows to \(String(format: "%.1f GB", Double(after) / 1e9))",
            bytes: macOS),
          OmarchyRemovalItem(
            title: "Apple system container", detail: "disk0s1", bytes: 524_288_000),
          OmarchyRemovalItem(title: "Apple Recovery", detail: recovery, bytes: 5_368_664_064),
        ]
      }
      func ticket(
        kind: OmarchyRemovalKind = .installation, macOS: UInt64, deletions: [OmarchyRemovalItem],
        free: UInt64 = 0, recovery: String, notes: [String] = [],
        startupDisk: OmarchyRemovalItem? = nil
      ) -> OmarchyRemovalTicket {
        let reclaim = deletions.reduce(free) { $0 + $1.bytes }
        return OmarchyRemovalTicket(
          id: UUID(), kind: kind, reclaimBytes: reclaim, macOSBytesAfter: macOS + reclaim,
          deletions: deletions,
          kept: kept(macOS: macOS, after: macOS + reclaim, recovery: recovery),
          notes: notes, startupDisk: startupDisk)
      }
      switch self {
      case .freeSpace:
        return (
          ticket(
            kind: .freeSpace, macOS: 461_600_000_000, deletions: [], free: 32_800_505_856,
            recovery: "disk0s6",
            notes: [
              "macOS takes all the unallocated space directly after it, whatever put it there."
            ]),
          "No installation was found, but 32.8 GB directly after macOS is unallocated. macOS can take it back. Nothing will be deleted."
        )
      case .asahi:
        return (
          ticket(
            macOS: 461_600_000_000,
            deletions: [
              OmarchyRemovalItem(
                title: "Startup container “Arch Linux ARM”", detail: "disk0s3 · APFS",
                bytes: 2_499_805_184),
              OmarchyRemovalItem(
                title: "EFI partition “EFI - ARCH”", detail: "disk0s4", bytes: 524_288_000),
              OmarchyRemovalItem(
                title: "Linux partition", detail: "disk0s5", bytes: 29_776_412_672),
            ], recovery: "disk0s6"),
          "Found “Arch Linux ARM”. Removal permanently deletes it and everything stored in it, then returns its space to macOS."
        )
      default:
        let startsUpFromOmarchy = [.startupDisk, .startupFailed].contains(self)
        return (
          ticket(
            macOS: 678_662_672_384,
            deletions: [
              OmarchyRemovalItem(
                title: "Startup container “Omarchy”", detail: "disk0s3 · APFS",
                bytes: 2_499_805_184),
              OmarchyRemovalItem(
                title: "EFI partition “EFI - OMARC”", detail: "disk0s4", bytes: 524_288_000),
              OmarchyRemovalItem(title: "Linux partition", detail: "disk0s5", bytes: 2_147_483_648),
              OmarchyRemovalItem(
                title: "Linux partition", detail: "disk0s6", bytes: 310_828_335_104),
            ], recovery: "disk0s7",
            startupDisk: startsUpFromOmarchy
              ? OmarchyRemovalItem(
                title: "Set macOS “Macintosh HD” as the startup disk",
                detail: "Your Mac starts up from “Omarchy” now", bytes: 0) : nil),
          startsUpFromOmarchy
            ? "Found “Omarchy”. Removal first sets macOS as the startup disk, then permanently deletes “Omarchy” and everything stored in it and returns its space to macOS."
            : "Found “Omarchy”. Removal permanently deletes it and everything stored in it, then returns its space to macOS."
        )
      }
    }

    var message: String {
      switch self {
      case .success:
        "“Omarchy” and its data have been removed. The freed space is now part of macOS."
      case .asahi:
        "“Arch Linux ARM” and its data have been removed. The freed space is now part of macOS."
      case .freeSpace: "The free space is now part of macOS."
      case .startupDisk:
        "“Omarchy” and its data have been removed. The freed space is now part of macOS."
      case .startupFailed:
        "macOS didn’t set “Macintosh HD” as the startup disk. It reported: “Failed to authenticate owner”. Nothing was deleted."
      case .none:
        "No Omarchy installation, or other installation made with the Asahi installer, was found, and there’s no unallocated space after macOS. Nothing was changed."
      case .ambiguous:
        "Found disk0s4 (EFI partition, “EFI - ARCH”, 524.3 MB); disk0s5 (Linux partition, 29.8 GB) without the startup container every installation made with the Asahi installer has. This looks like a partly removed installation, which needs a manual review. Nothing was changed."
      case .helperUnavailable:
        PlainLanguage.removalServiceNotResponding
      case .credentials:
        "The macOS account or password was not accepted. No disk changes were made."
      case .changed:
        "The disk layout changed since you reviewed it. No disk changes were made. Close this window and review removal again."
      case .interrupted:
        "Removal stopped, and some Omarchy data may already be deleted. Don’t start removal again; the removal record was kept for recovery."
      case .reclaimFailed:
        "Omarchy was removed, but the installer couldn’t confirm its space went back to macOS. The space may still be unallocated. Don’t start removal again; the removal record was kept for recovery."
      case .disconnected:
        "The connection to the removal service was lost. Removal may still be running. Don’t restart removal or turn off this Mac. Check the removal record before continuing."
      }
    }
  }
#endif
