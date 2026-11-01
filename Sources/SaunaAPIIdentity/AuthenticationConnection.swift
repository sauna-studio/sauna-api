import NIOCore
package import PostgresNIO
import Synchronization

/// Close only the cancelled operation's leased connection. The close future is
/// awaited before the pool lease is returned, so a late cancellation cannot
/// close a connection already borrowed by another request.
private final class AuthenticationLease: Sendable {
  private struct State {
    let connection: PostgresConnection
    var finished = false
    var closing: EventLoopFuture<Void>?
  }
  private let state: Mutex<State>
  init(_ connection: PostgresConnection) { state = Mutex(State(connection: connection)) }
  func cancel() {
    state.withLock { state in
      guard !state.finished, state.closing == nil else { return }
      state.closing = state.connection.close()
    }
  }
  func finish() async {
    let closing = state.withLock { state in
      state.finished = true
      return state.closing
    }
    // The query's original result/error remains authoritative. A failed close
    // also denotes a dead connection; it must finish before releasing the lease.
    if let closing { _ = try? await closing.get() }
  }
}

package func authenticationConnection<Value: Sendable>(
  _ client: PostgresClient,
  operation: @escaping @concurrent @Sendable (PostgresConnection) async throws -> Value
) async throws -> Value {
  try await client.withConnection { connection in
    let lease = AuthenticationLease(connection)
    let result: Result<Value, any Error> = await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        return .success(try await operation(connection))
      } catch { return .failure(error) }
    } onCancel: {
      lease.cancel()
    }
    if case .failure(let error) = result, error is CancellationError { lease.cancel() }
    await lease.finish()
    try Task.checkCancellation()
    return try result.get()
  }
}

/// On cancellation the owning lease closes the connection, causing PostgreSQL
/// to roll back. Do not enqueue ROLLBACK onto that closed channel: the pinned
/// driver's generic transaction helper does so even for a cancelled operation.
func authenticationTransaction<Value: Sendable>(
  _ client: PostgresClient,
  operation: @escaping @concurrent @Sendable (PostgresConnection) async throws -> Value
) async throws -> Value {
  try await authenticationConnection(client) { connection in
    _ = try await authQuery("BEGIN", on: connection).collect()
    do {
      let result = try await operation(connection)
      try Task.checkCancellation()
      _ = try await authQuery("COMMIT", on: connection).collect()
      return result
    } catch {
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      guard !connection.isClosed else { throw AuthenticationError.unavailable }
      do { _ = try await authQuery("ROLLBACK", on: connection).collect() } catch {
        // Discard a connection whose transaction state is no longer known.
        _ = try? await connection.close()
        throw AuthenticationError.unavailable
      }
      throw error
    }
  }
}
