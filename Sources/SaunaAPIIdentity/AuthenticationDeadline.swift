/// Per-operation deadline. Cancels only this structured operation, never the
/// shared pool's run task. Child operations must finish cancellation before exit.
package func authenticationDeadline<Value: Sendable>(
    timeout: Duration = .seconds(10),
    operation: @escaping @concurrent @Sendable () async throws -> Value
) async throws -> Value {
    guard timeout >= .milliseconds(1), timeout <= .seconds(10) else { throw AuthenticationError.invalidInput }
    do {
        return try await withThrowingTaskGroup(of: Value.self) { tasks in
            tasks.addTask { try await operation() }
            tasks.addTask { try await Task.sleep(for: timeout); throw AuthenticationError.unavailable }
            defer { tasks.cancelAll() }
            guard let result = try await tasks.next() else { throw AuthenticationError.unavailable }
            try Task.checkCancellation()
            return result
        }
    } catch {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        throw error
    }
}
