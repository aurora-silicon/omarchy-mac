#if os(macOS)
  import Foundation

  /// Created only by app-side checks that fail before an execution request is sent.
  /// A transport failure after submission must never be wrapped in this type.
  public struct InstallerPreSubmissionFailure: Error, Sendable {
    public let underlying: any Error

    public init(_ underlying: any Error) {
      self.underlying = underlying
    }
  }

  public struct InstallerExecutionCoordinator: Sendable {
    private let processAdapter = ClosedEngineProcessAdapter()

    private let ping: @Sendable (AuthenticatedEngineXPCSubmitter) async throws -> Void

    public init() {
      ping = { try await $0.ping() }
    }

    init(ping: @escaping @Sendable (AuthenticatedEngineXPCSubmitter) async throws -> Void) {
      self.ping = ping
    }

    public func execute(
      _ prepared: PreparedInstallerPlanExecution,
      approval: CandidateBoundPlanApproval,
      configuration: InstallerReleaseConfiguration,
      handoffDirectory: URL,
      machineOwnerAuthorization: MachineOwnerAuthorization,
      journalProgress: (@Sendable (Data) -> Void)? = nil
    ) async throws -> InstallerExecutionProgress {
      try await execute(
        prepared,
        approval: approval,
        configuration: configuration,
        handoffDirectory: handoffDirectory,
        machineOwnerAuthorization: machineOwnerAuthorization,
        operation: .install,
        journalProgress: journalProgress
      )
    }

    public func retryRecoveryAuthorization(
      _ prepared: PreparedInstallerPlanExecution,
      approval: CandidateBoundPlanApproval,
      configuration: InstallerReleaseConfiguration,
      handoffDirectory: URL,
      machineOwnerAuthorization: MachineOwnerAuthorization,
      journalProgress: (@Sendable (Data) -> Void)? = nil
    ) async throws -> InstallerExecutionProgress {
      try await execute(
        prepared,
        approval: approval,
        configuration: configuration,
        handoffDirectory: handoffDirectory,
        machineOwnerAuthorization: machineOwnerAuthorization,
        operation: .retryRecoveryAuthorization,
        journalProgress: journalProgress
      )
    }

    private func execute(
      _ prepared: PreparedInstallerPlanExecution,
      approval: CandidateBoundPlanApproval,
      configuration: InstallerReleaseConfiguration,
      handoffDirectory: URL,
      machineOwnerAuthorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation,
      journalProgress: (@Sendable (Data) -> Void)?
    ) async throws -> InstallerExecutionProgress {
      let submitter: AuthenticatedEngineXPCSubmitter
      do {
        submitter = try AuthenticatedEngineXPCSubmitter(
          machServiceName: configuration.helperMachServiceName,
          helperCodeSigningRequirement: configuration.helperCodeSigningRequirement,
          journalProgress: journalProgress
        )
        // Ping sends no execution request, handoff or credentials.
        try await ping(submitter)
      } catch {
        throw InstallerPreSubmissionFailure(error)
      }
      let process = ClosedEngineHandoffProcess(
        assets: prepared.review.assets,
        handoffDirectory: handoffDirectory,
        submitter: submitter,
        authorization: machineOwnerAuthorization,
        operation: operation
      )
      return try await execute(
        prepared,
        approval: approval,
        process: process
      )
    }

    func execute(
      _ prepared: PreparedInstallerPlanExecution,
      approval: CandidateBoundPlanApproval,
      process: any EngineProcessExecuting
    ) async throws -> InstallerExecutionProgress {
      let transcript = try await processAdapter.execute(
        prepared.candidateRequest,
        approval: approval,
        authorization: CandidateBoundExecutionAuthorization(
          approval: approval
        ),
        process: process
      )
      return try InstallerExecutionProgress(
        review: prepared.review,
        transcript: transcript
      )
    }
  }

  private struct CandidateBoundExecutionAuthorization:
    EngineExecutionAuthorizing
  {
    let approval: CandidateBoundPlanApproval

    func decision(
      for invocation: ClosedEngineInvocation
    ) async -> EngineAuthorizationDecision {
      guard approval.identity == invocation.candidateIdentity,
        approval.approvedBindingDigest
          == invocation.candidateIdentity.bindingDigest
      else {
        return .cancelled
      }
      return .granted
    }
  }
#endif
