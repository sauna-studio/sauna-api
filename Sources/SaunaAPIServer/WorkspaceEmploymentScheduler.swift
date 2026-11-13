package import SaunaAPIDatabase
package import ServiceLifecycle

/// Internal worker for explicitly configured employment checks. No worker starts unless
/// a composition root supplies a Directory verifier and registers the service.
package struct WorkspaceEmploymentScheduler: Service {
    private let claim: @Sendable () async throws -> WorkspaceEmploymentClaim?
    private let verify: @Sendable (WorkspaceEmploymentClaim) async -> WorkspaceEmploymentOutcome
    private let finish: @Sendable (WorkspaceEmploymentClaim, WorkspaceEmploymentOutcome) async throws -> Void
    private let sleep: @Sendable (Duration) async throws -> Void

    /// The verifier must bound its IO and honor cancellation. The database lease
    /// independently limits when its result can be applied.
    package init(
        store: WorkspaceEmploymentStore,
        verify: @escaping @Sendable (WorkspaceEmploymentClaim) async -> WorkspaceEmploymentOutcome
    ) {
        self.init(
            claim: { try await store.claimNextDue(leaseSeconds: 60) },
            verify: verify,
            finish: { claim, outcome in
                let retry = switch outcome {
                case .unavailable: 300
                case .eligible, .ineligible: 3_600
                }
                _ = try await store.finish(claim, outcome: outcome, retryAfterSeconds: retry)
            },
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    init(
        claim: @escaping @Sendable () async throws -> WorkspaceEmploymentClaim?,
        verify: @escaping @Sendable (WorkspaceEmploymentClaim) async -> WorkspaceEmploymentOutcome,
        finish: @escaping @Sendable (WorkspaceEmploymentClaim, WorkspaceEmploymentOutcome) async throws -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.claim = claim
        self.verify = verify
        self.finish = finish
        self.sleep = sleep
    }

    package func run() async throws {
        try await cancelWhenGracefulShutdown {
            try await poll()
        }
    }

    private func poll() async throws {
        while !Task.isCancelled {
            do {
                if let snapshot = try await claim() {
                    try Task.checkCancellation()
                    let outcome = await verify(snapshot)
                    try Task.checkCancellation()
                    try await finish(snapshot, outcome)
                }
            } catch {
                // A failed finish can have committed. The next poll must claim
                // again rather than reapply an outcome from an old snapshot.
                if Task.isCancelled { return }
            }
            do {
                try await sleep(.seconds(5))
            } catch is CancellationError where Task.isCancelled {
                return
            }
        }
    }
}
