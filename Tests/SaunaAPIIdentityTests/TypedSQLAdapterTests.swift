import Foundation
import PostgresNIO
import Testing
@testable import SaunaAPIIdentity

struct TypedSQLAdapterTests {
    @Test func credentialLookupUsesTypedProjectionBoundIDAndRowLock() throws {
        let id = Data(repeating: 0x11, count: 32) // public synthetic test vector
        let query = try AuthTypedQueries.credentialForAuthentication(id: id)
        #expect(query.sql.hasSuffix("FOR UPDATE"))
        #expect(query.sql.contains("revoked_at"))
        #expect(query.sql.contains("$1"))
        #expect(query.binds.count == 1)
        var expected = PostgresBindings()
        try expected.append(id)
        let correctBinding = query.binds == expected
        #expect(correctBinding)
        let count = try AuthTypedQueries.credentialAvailability(id: id)
        #expect(count.sql.lowercased().contains("count("))
        #expect(count.binds.count == 1)
    }

    @Test func sessionSecurityPredicatesStayInOneQueryAndInputsNeverBecomeSQLText() throws {
        let tokenHash = Data(repeating: 0x22, count: 32)
        let hostileOrigin = "synthetic' OR TRUE --"
        let query = try AuthTypedQueries.sessionLookup(tokenHash: tokenHash, origin: hostileOrigin)
        #expect(query.sql.contains("EXISTS"))
        #expect(query.sql.contains("c.revoked_at IS NULL"))
        #expect(query.sql.contains("clock_timestamp()"))
        #expect(query.sql.contains("expires_at"))
        #expect(!query.sql.contains(hostileOrigin))
        #expect(query.binds.count == 2)
        var expected = PostgresBindings()
        try expected.append(tokenHash)
        expected.append(hostileOrigin)
        let correctBindingOrder = query.binds == expected
        #expect(correctBindingOrder)
    }

    @Test func revocationUsesDatabaseClockAndTypedUUIDOrHashBindings() throws {
        let hash = Data(repeating: 0x33, count: 32)
        let origin = "http://localhost:5173"
        let single = try AuthTypedQueries.revokeSession(tokenHash: hash, origin: origin)
        #expect(single.sql.hasPrefix("UPDATE"))
        #expect(single.sql.contains("clock_timestamp()"))
        #expect(single.sql.contains("IS NULL"))
        #expect(single.binds.count == 2)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let all = try AuthTypedQueries.revokeAllSessions(userID: id)
        #expect(all.binds.count == 1)
        var expected = PostgresBindings()
        expected.append(id)
        let UUIDStayedTyped = all.binds == expected
        #expect(UUIDStayedTyped)
    }
}
