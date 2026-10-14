#if os(macOS)
  import Darwin
  import Foundation
  import Security
  import RecoveryAccountCore

  @objc public protocol ClosedEngineXPCService {
    /// Answers as soon as the helper is up. The app calls this before it
    /// sends anything, so a helper that launchd cannot keep alive fails in
    /// seconds instead of leaving a request queued forever.
    func ping(reply: @escaping @Sendable (Bool) -> Void)

    /// The helper's build version, or an empty string when it carries none.
    /// Helpers installed by the installer package predate this call and never
    /// answer it.
    func helperVersion(reply: @escaping @Sendable (String) -> Void)

    func recoveryAccount(
      action: String, ticket: String, username: String, password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void)

    /// Removes the installer app the installer package left in
    /// /Applications, when that is safe; replies with a summary for logs.
    /// See `PackageInstalledAppRetirement`.
    func retirePackageInstalledApps(reply: @escaping @Sendable (String) -> Void)

    /// Yes if no job runs and no other app holds the replacement; the helper
    /// then refuses new jobs until it is replaced, the hold is released, or
    /// it lapses. The same token renews the hold. Helpers older than this
    /// call never answer it.
    func prepareForReplacement(token: String, reply: @escaping @Sendable (Bool) -> Void)

    func cancelReplacement(token: String, reply: @escaping @Sendable () -> Void)

    func removal(
      ticket: String, confirmation: String, machineOwner: String, password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    /// A `RemovalFinalization` raw value for the removal with this ticket,
    /// for an app whose removal reply was lost. Helpers older than this call
    /// never answer it.
    func removalFinalization(ticket: String, reply: @escaping @Sendable (String) -> Void)

    func submit(
      packageDirectory: FileHandle,
      operation: String,
      machineOwner: String,
      password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    func writeInstallConf(
      document: Data,
      storeIdentifier: String,
      offsetBytes: UInt64,
      lengthBytes: UInt64,
      machineOwner: String,
      password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    )
  }

  public enum EngineXPCSubmissionError: Error, Equatable, Sendable {
    case invalidMachServiceName
    case invalidCodeSigningRequirement
    case unsafeHandoffPackage
    case connectionFailed
    /// The helper did not answer a ping within the allowed time. Seen when
    /// launchd respawns a helper that exits at startup: the mach message
    /// stays queued and nothing ever replies or interrupts.
    case helperUnresponsive
    case recoveryAuthorizationFailed
    case machineOwnerCredentialsRejected
    case helperRejected(domain: String, code: Int)
    /// The pinned engine stopped with an error. Display and diagnostics only:
    /// nothing in it may decide trust, and the summary is untrusted text.
    case engineFailed(EngineFailureNotice)
    case emptyResponse
    /// The request was never handed to the helper: it didn't answer before
    /// sending, or no connection could be made. Nothing started.
    case notSubmitted
  }

  public struct AuthenticatedEngineXPCSubmitter:
    EngineHandoffSubmitting, Sendable
  {
    private let machServiceName: String
    private let helperCodeSigningRequirement: String
    private let journalProgress: (@Sendable (Data) -> Void)?

    public init(
      machServiceName: String,
      helperCodeSigningRequirement: String,
      journalProgress: (@Sendable (Data) -> Void)? = nil
    ) throws {
      guard Self.isMachServiceName(machServiceName) else {
        throw EngineXPCSubmissionError.invalidMachServiceName
      }
      guard
        EngineCodeSigningRequirement.isValid(
          helperCodeSigningRequirement
        )
      else {
        throw EngineXPCSubmissionError.invalidCodeSigningRequirement
      }
      self.machServiceName = machServiceName
      self.helperCodeSigningRequirement = helperCodeSigningRequirement
      self.journalProgress = journalProgress
    }

    /// A privileged connection to the helper, pinned to its code-signing
    /// requirement; each call gets its own so a dead one never lingers.
    private func makeConnection() -> NSXPCConnection {
      let connection = NSXPCConnection(
        machServiceName: machServiceName,
        options: .privileged
      )
      connection.remoteObjectInterface = NSXPCInterface(
        with: ClosedEngineXPCService.self
      )
      connection.setCodeSigningRequirement(helperCodeSigningRequirement)
      return connection
    }

    /// Confirms the helper answers before any credentials or package are
    /// sent. A missing service fails through the connection handlers; a
    /// service launchd cannot keep alive answers nothing at all, which is
    /// what the timeout is for.
    public func ping(timeout: Duration = .seconds(8)) async throws {
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      let timer = Task {
        try await Task.sleep(for: timeout)
        connectionHandle.invalidate()
      }
      defer { timer.cancel() }
      let answered: Bool = try await withCheckedThrowingContinuation { continuation in
        let gate = EngineXPCPingGate(continuation: continuation)
        connection.interruptionHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.invalidationHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.helperUnresponsive)
        }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
          }) as? ClosedEngineXPCService
        else {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
          connectionHandle.invalidate()
          return
        }
        proxy.ping { answer in
          gate.resume(returning: answer)
          connectionHandle.invalidate()
        }
      }
      guard answered else {
        throw EngineXPCSubmissionError.helperUnresponsive
      }
    }

    /// How a ping went, for deciding what to do with an installed helper.
    public enum PingResult: Equatable, Sendable {
      /// The helper answered yes.
      case answered
      /// The connection ended before the timeout without a yes: nothing is
      /// listening, or the helper refused this app, as a helper from another
      /// build does, or it is uninstalling itself.
      case refused
      /// No answer within the timeout: the helper may just be busy with a long
      /// job, so it must not be treated as broken or replaced on that alone.
      case noAnswer
    }

    public func pingResult(timeout: Duration = .seconds(8)) async -> PingResult {
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      let timedOut = EngineXPCFlag()
      let timer = Task {
        try await Task.sleep(for: timeout)
        timedOut.set()
        connectionHandle.invalidate()
      }
      defer { timer.cancel() }
      let answered: Bool? = await withCheckedContinuation { continuation in
        let gate = EngineXPCOptionalBoolGate(continuation: continuation)
        connection.interruptionHandler = { gate.resume(returning: nil) }
        connection.invalidationHandler = { gate.resume(returning: nil) }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(returning: nil)
          }) as? ClosedEngineXPCService
        else {
          gate.resume(returning: nil)
          connectionHandle.invalidate()
          return
        }
        proxy.ping { answer in
          gate.resume(returning: answer)
          connectionHandle.invalidate()
        }
      }
      if answered == true {
        return .answered
      }
      return timedOut.isSet ? .noAnswer : .refused
    }

    /// Nil when the helper doesn't answer in time, as helpers older than the
    /// call never do.
    public func prepareForReplacement(
      token: String, timeout: Duration = .seconds(3)
    ) async -> Bool? {
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      let timer = Task {
        try await Task.sleep(for: timeout)
        connectionHandle.invalidate()
      }
      defer { timer.cancel() }
      return await withCheckedContinuation { continuation in
        let gate = EngineXPCOptionalBoolGate(continuation: continuation)
        connection.interruptionHandler = { gate.resume(returning: nil) }
        connection.invalidationHandler = { gate.resume(returning: nil) }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(returning: nil)
          }) as? ClosedEngineXPCService
        else {
          gate.resume(returning: nil)
          connectionHandle.invalidate()
          return
        }
        proxy.prepareForReplacement(token: token) { granted in
          gate.resume(returning: granted)
          connectionHandle.invalidate()
        }
      }
    }

    public func cancelReplacement(token: String, timeout: Duration = .seconds(3)) async {
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      let timer = Task {
        try await Task.sleep(for: timeout)
        connectionHandle.invalidate()
      }
      defer { timer.cancel() }
      _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
        let gate = EngineXPCOptionalBoolGate(continuation: continuation)
        connection.interruptionHandler = { gate.resume(returning: nil) }
        connection.invalidationHandler = { gate.resume(returning: nil) }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(returning: nil)
          }) as? ClosedEngineXPCService
        else {
          gate.resume(returning: nil)
          connectionHandle.invalidate()
          return
        }
        proxy.cancelReplacement(token: token) {
          gate.resume(returning: true)
          connectionHandle.invalidate()
        }
      }
    }

    /// Asks the helper to remove the installer app the package left behind.
    /// Returns the helper's summary, or nil when it does not answer in time.
    public func retirePackageInstalledApps(timeout: Duration = .seconds(10)) async -> String? {
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      let timer = Task {
        try await Task.sleep(for: timeout)
        connectionHandle.invalidate()
      }
      defer { timer.cancel() }
      let summary: String = await withCheckedContinuation { continuation in
        let gate = EngineXPCStringGate(continuation: continuation)
        connection.interruptionHandler = { gate.resume(returning: "") }
        connection.invalidationHandler = { gate.resume(returning: "") }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(returning: "")
          }) as? ClosedEngineXPCService
        else {
          gate.resume(returning: "")
          connectionHandle.invalidate()
          return
        }
        proxy.retirePackageInstalledApps { reported in
          gate.resume(returning: reported)
          connectionHandle.invalidate()
        }
      }
      return summary.isEmpty ? nil : summary
    }

    /// The build version the running helper reports, or nil when it reports
    /// none, does not answer in time, or cannot be reached. An older helper
    /// that lacks the call simply never replies, so the timeout is short.
    public func helperVersion(timeout: Duration = .seconds(3)) async -> String? {
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      let timer = Task {
        try await Task.sleep(for: timeout)
        connectionHandle.invalidate()
      }
      defer { timer.cancel() }
      let version: String = await withCheckedContinuation { continuation in
        let gate = EngineXPCStringGate(continuation: continuation)
        connection.interruptionHandler = { gate.resume(returning: "") }
        connection.invalidationHandler = { gate.resume(returning: "") }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(returning: "")
          }) as? ClosedEngineXPCService
        else {
          gate.resume(returning: "")
          connectionHandle.invalidate()
          return
        }
        proxy.helperVersion { reported in
          gate.resume(returning: reported)
          connectionHandle.invalidate()
        }
      }
      return version.isEmpty ? nil : version
    }

    public func removal(
      ticket: OmarchyRemovalTicket? = nil, confirmation: String = "",
      authorization: MachineOwnerAuthorization? = nil
    ) async throws -> OmarchyRemovalReply {
      // Failures before the request is handed over mean nothing started, and
      // are told apart from a reply lost after sending.
      do {
        try await ping()
      } catch {
        throw EngineXPCSubmissionError.notSubmitted
      }
      let connection = makeConnection()
      let handle = SendableXPCConnection(connection)
      let data: Data = try await withCheckedThrowingContinuation { continuation in
        let gate = EngineXPCReplyGate(continuation: continuation)
        connection.interruptionHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.invalidationHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
            handle.invalidate()
          }) as? ClosedEngineXPCService
        else {
          gate.resume(throwing: EngineXPCSubmissionError.notSubmitted)
          handle.invalidate()
          return
        }
        proxy.removal(
          ticket: ticket?.id.uuidString ?? "", confirmation: confirmation,
          machineOwner: authorization?.username ?? "", password: authorization?.password ?? Data()
        ) { response, error in
          defer { handle.invalidate() }
          if let error {
            gate.resume(throwing: error)
          } else if let response {
            gate.resume(returning: response)
          } else {
            gate.resume(throwing: EngineXPCSubmissionError.emptyResponse)
          }
        }
      }
      return try JSONDecoder().decode(OmarchyRemovalReply.self, from: data)
    }

    public func recoveryAccount(
      action: String, ticket: String = "", username: String = "", password: Data = Data()
    ) async throws -> RecoveryAccountReply {
      let connection = makeConnection()
      let handle = SendableXPCConnection(connection)
      let timer = Task {
        try await Task.sleep(for: .seconds(180))
        handle.invalidate()
      }
      defer { timer.cancel() }
      let data: Data = try await withCheckedThrowingContinuation { continuation in
        let gate = EngineXPCReplyGate(continuation: continuation)
        connection.interruptionHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.invalidationHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
            handle.invalidate()
          }) as? ClosedEngineXPCService
        else {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
          handle.invalidate()
          return
        }
        proxy.recoveryAccount(
          action: action, ticket: ticket, username: username, password: password
        ) { response, error in
          defer { handle.invalidate() }
          if let error {
            gate.resume(throwing: error)
          } else if let response {
            gate.resume(returning: response)
          } else {
            gate.resume(throwing: EngineXPCSubmissionError.emptyResponse)
          }
        }
      }
      let reply = try JSONDecoder().decode(RecoveryAccountReply.self, from: data)
      if let message = reply.message { throw AccountSetupFailure(message) }
      return reply
    }

    /// What the helper's records say about the removal with this ticket, or
    /// nil when it doesn't answer in time, as helpers older than the call
    /// never do, or answers something unknown.
    public func removalFinalization(
      ticket: UUID, timeout: Duration = .seconds(10)
    ) async -> RemovalFinalization? {
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      let timer = Task {
        try await Task.sleep(for: timeout)
        connectionHandle.invalidate()
      }
      defer { timer.cancel() }
      let answer: String = await withCheckedContinuation { continuation in
        let gate = EngineXPCStringGate(continuation: continuation)
        connection.interruptionHandler = { gate.resume(returning: "") }
        connection.invalidationHandler = { gate.resume(returning: "") }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(returning: "")
          }) as? ClosedEngineXPCService
        else {
          gate.resume(returning: "")
          connectionHandle.invalidate()
          return
        }
        proxy.removalFinalization(ticket: ticket.uuidString) { reported in
          gate.resume(returning: reported)
          connectionHandle.invalidate()
        }
      }
      return RemovalFinalization(rawValue: answer)
    }

    public func submit(
      _ handoff: PreparedEngineHandoff,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation
    ) async throws -> Data {
      let descriptor = Darwin.open(
        handoff.packageURL.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else {
        throw EngineXPCSubmissionError.unsafeHandoffPackage
      }

      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFDIR,
        status.st_mode & 0o077 == 0
      else {
        Darwin.close(descriptor)
        throw EngineXPCSubmissionError.unsafeHandoffPackage
      }

      let directoryHandle = FileHandle(
        fileDescriptor: descriptor,
        closeOnDealloc: true
      )
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      if let journalProgress {
        connection.exportedInterface = NSXPCInterface(
          with: ClosedEngineProgressClient.self
        )
        connection.exportedObject = EngineProgressClientRelay(
          handler: journalProgress
        )
      }

      return try await withCheckedThrowingContinuation { continuation in
        let gate = EngineXPCReplyGate(continuation: continuation)
        connection.interruptionHandler = {
          gate.resume(
            throwing: EngineXPCSubmissionError.connectionFailed
          )
        }
        connection.invalidationHandler = {
          gate.resume(
            throwing: EngineXPCSubmissionError.connectionFailed
          )
        }
        connection.activate()

        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(
              throwing: EngineXPCSubmissionError.connectionFailed
            )
            connectionHandle.invalidate()
          }) as? ClosedEngineXPCService
        else {
          gate.resume(
            throwing: EngineXPCSubmissionError.connectionFailed
          )
          connectionHandle.invalidate()
          return
        }

        proxy.submit(
          packageDirectory: directoryHandle,
          operation: operation.rawValue,
          machineOwner: authorization.username,
          password: authorization.password
        ) { response, error in
          defer { connectionHandle.invalidate() }
          if let error {
            gate.resume(
              throwing: EngineXPCErrorBridge.submissionError(error)
            )
          } else if let response, !response.isEmpty {
            gate.resume(returning: response)
          } else {
            gate.resume(
              throwing: EngineXPCSubmissionError.emptyResponse
            )
          }
        }
      }
    }

    public func writeInstallConf(
      _ conf: InstallConf,
      storeIdentifier: String,
      offsetBytes: UInt64,
      lengthBytes: UInt64,
      authorization: MachineOwnerAuthorization
    ) async throws -> InstallConfHandoff {
      try await ping()
      let connection = makeConnection()
      let handle = SendableXPCConnection(connection)
      let data: Data = try await withCheckedThrowingContinuation { continuation in
        let gate = EngineXPCReplyGate(continuation: continuation)
        connection.interruptionHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.invalidationHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
            handle.invalidate()
          }) as? ClosedEngineXPCService
        else {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
          handle.invalidate()
          return
        }
        proxy.writeInstallConf(
          document: conf.serializedData,
          storeIdentifier: storeIdentifier,
          offsetBytes: offsetBytes,
          lengthBytes: lengthBytes,
          machineOwner: authorization.username,
          password: authorization.password
        ) { response, error in
          defer { handle.invalidate() }
          do {
            let payload = try InstallConfXPCCodec.decodeReply(data: response, error: error)
            gate.resume(returning: payload)
          } catch {
            gate.resume(throwing: error)
          }
        }
      }
      return try InstallConfXPCCodec.decode(data)
    }

    static func isMachServiceName(_ value: String) -> Bool {
      guard (3...255).contains(value.utf8.count),
        value.contains("."),
        value.first != ".",
        value.last != "."
      else {
        return false
      }
      return value.utf8.allSatisfy { byte in
        (byte >= 48 && byte <= 57)
          || (byte >= 65 && byte <= 90)
          || (byte >= 97 && byte <= 122)
          || byte == 45
          || byte == 46
      }
    }
  }

  enum InstallConfXPCCodec {
    static func encode(_ handoff: InstallConfHandoff) throws -> Data {
      try JSONEncoder().encode(handoff)
    }

    static func decode(_ data: Data) throws -> InstallConfHandoff {
      try JSONDecoder().decode(InstallConfHandoff.self, from: data)
    }

    static func encodeReply(
      error: (any Error)?,
      encrypt: Bool
    ) -> (Data?, NSError?) {
      func payload(_ handoff: InstallConfHandoff) -> (Data?, NSError?) {
        do {
          return (try encode(handoff), nil)
        } catch {
          return (nil, EngineXPCErrorBridge.serviceError(for: error))
        }
      }
      guard let error else {
        return payload(.recorded)
      }
      if let esp = error as? InstallConfESPError {
        return payload(
          esp.followedConfirmedWrite ? .unconfirmed(encrypt: encrypt) : .notRecorded
        )
      }
      return (nil, EngineXPCErrorBridge.serviceError(for: error))
    }

    static func decodeReply(data: Data?, error: NSError?) throws -> Data {
      if let error {
        throw EngineXPCErrorBridge.submissionError(error)
      }
      guard let data, !data.isEmpty else {
        throw EngineXPCSubmissionError.emptyResponse
      }
      return data
    }
  }

  enum EngineXPCErrorBridge {
    private static let recoveryAuthorizationDomain =
      InstallerProductIdentity.appIdentifier + ".recovery-authorization"
    private static let recoveryAuthorizationCode = 1
    // Dedicated domain so the app can tell "wrong password" from every other
    // helper rejection. Skew-safe: an older app maps this unknown domain to the
    // generic helperRejected case exactly as it does today.
    static let machineOwnerAuthorizationDomain =
      InstallerProductIdentity.appIdentifier + ".machine-owner-authorization"
    static let machineOwnerAuthorizationCode = 1
    // The engine's typed failure. The code is the EngineFailureReason raw
    // value; userInfo carries only an exit status, a Boolean and one redacted,
    // bounded summary line. Never the stderr tail, never credentials.
    // Skew-safe like the domain above: an older app sees helperRejected.
    static let engineFailureDomain = InstallerProductIdentity.appIdentifier + ".engine-failure"
    static let exitStatusKey = "exitStatus"
    static let diskUnchangedKey = "diskUnchanged"
    static let summaryKey = "summary"

    static func serviceError(for error: any Error) -> NSError {
      if let executionError = error as? PinnedAsahiEngineExecutionError,
        case .engineFailed(let report) = executionError
      {
        let notice = report.notice
        return NSError(
          domain: engineFailureDomain,
          code: notice.reason.rawValue,
          userInfo: [
            exitStatusKey: NSNumber(value: notice.exitStatus),
            diskUnchangedKey: NSNumber(value: notice.diskUnchanged),
            summaryKey: EngineFailureNotice.sanitizedSummary(notice.summary) as NSString,
          ]
        )
      }
      if let executionError = error
        as? PinnedAsahiEngineExecutionError,
        executionError == .recoveryAuthorizationFailed
      {
        return NSError(
          domain: recoveryAuthorizationDomain,
          code: recoveryAuthorizationCode,
          userInfo: [:]
        )
      }
      if let helperError = error as? ClosedEngineHelperError,
        helperError == .invalidMachineOwnerCredentials
      {
        return NSError(
          domain: machineOwnerAuthorizationDomain,
          code: machineOwnerAuthorizationCode,
          userInfo: [:]
        )
      }
      return error as NSError
    }

    static func submissionError(
      _ error: NSError
    ) -> EngineXPCSubmissionError {
      if error.domain == recoveryAuthorizationDomain,
        error.code == recoveryAuthorizationCode
      {
        return .recoveryAuthorizationFailed
      }
      if error.domain == machineOwnerAuthorizationDomain,
        error.code == machineOwnerAuthorizationCode
      {
        return .machineOwnerCredentialsRejected
      }
      if error.domain == engineFailureDomain {
        let exitStatus = (error.userInfo[exitStatusKey] as? NSNumber)?.int32Value ?? -1
        let unchanged = error.userInfo[diskUnchangedKey] as? NSNumber
        // Only an explicit Boolean true counts; anything else makes no claim.
        let diskUnchanged =
          unchanged.map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        return .engineFailed(
          EngineFailureNotice(
            reason: EngineFailureReason(rawValue: error.code) ?? .unclassified,
            exitStatus: exitStatus,
            diskUnchanged: diskUnchanged,
            summary: error.userInfo[summaryKey] as? String ?? ""
          )
        )
      }
      return .helperRejected(
        domain: error.domain,
        code: error.code
      )
    }
  }

  public enum RecoveryAuthorizationRetryPolicy {
    public static func isEligible(after error: any Error) -> Bool {
      guard let submissionError = error as? EngineXPCSubmissionError
      else {
        return false
      }
      return submissionError == .recoveryAuthorizationFailed
    }
  }

  enum EngineCodeSigningRequirement {
    static func isValid(_ value: String) -> Bool {
      guard !value.isEmpty, value.utf8.count <= 4_096 else {
        return false
      }
      var requirement: SecRequirement?
      let status = SecRequirementCreateWithString(
        value as CFString,
        SecCSFlags(),
        &requirement
      )
      return status == errSecSuccess && requirement != nil
    }
  }

  private final class SendableXPCConnection: @unchecked Sendable {
    private let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
      self.connection = connection
    }

    func invalidate() {
      connection.invalidate()
    }
  }

  /// One-shot resume for `ping`, the same shape as the reply gate below.
  private final class EngineXPCPingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, any Error>?

    init(continuation: CheckedContinuation<Bool, any Error>) {
      self.continuation = continuation
    }

    func resume(returning value: Bool) {
      takeContinuation()?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
      takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<Bool, any Error>? {
      lock.lock()
      defer { lock.unlock() }
      let candidate = continuation
      continuation = nil
      return candidate
    }
  }

  private final class EngineXPCFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
  }

  private final class EngineXPCOptionalBoolGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool?, Never>?

    init(continuation: CheckedContinuation<Bool?, Never>) {
      self.continuation = continuation
    }

    func resume(returning value: Bool?) {
      lock.lock()
      let candidate = continuation
      continuation = nil
      lock.unlock()
      candidate?.resume(returning: value)
    }
  }

  private final class EngineXPCStringGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?

    init(continuation: CheckedContinuation<String, Never>) {
      self.continuation = continuation
    }

    func resume(returning value: String) {
      lock.lock()
      let candidate = continuation
      continuation = nil
      lock.unlock()
      candidate?.resume(returning: value)
    }
  }

  private final class EngineXPCReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?

    init(continuation: CheckedContinuation<Data, any Error>) {
      self.continuation = continuation
    }

    func resume(returning data: Data) {
      takeContinuation()?.resume(returning: data)
    }

    func resume(throwing error: any Error) {
      takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<Data, any Error>? {
      lock.lock()
      defer { lock.unlock() }
      let candidate = continuation
      continuation = nil
      return candidate
    }
  }

  private final class EngineXPCVoidGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(continuation: CheckedContinuation<Void, any Error>) {
      self.continuation = continuation
    }

    func resume(returning _: Void) {
      takeContinuation()?.resume(returning: ())
    }

    func resume(throwing error: any Error) {
      takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<Void, any Error>? {
      lock.lock()
      defer { lock.unlock() }
      let candidate = continuation
      continuation = nil
      return candidate
    }
  }
#endif
