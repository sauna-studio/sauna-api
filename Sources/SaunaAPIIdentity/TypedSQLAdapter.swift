import Foundation
import ISO_9075_Foundation
import PostgreSQL
import PostgresNIO
import SQL
import SQL_Foundation_Integration
import SQL_Macros

/// Read projections declare only columns used by authentication. Atlas/schema.sql
/// remains the schema source of truth; these macros do not generate migrations.
@Table("passkey_credentials", schema: "public")
private struct CredentialSQLRow {
    var id: Data
    @Column("user_id") var userID: UUID
    @Column("user_handle") var userHandle: Data
    @Column("public_key_cose") var publicKeyCOSE: Data
    @Column("sign_count") var signCount: Int64
    @Column("backup_eligible") var backupEligible: Bool
    @Column("revoked_at") var revokedAt: Date?
}

@Table("auth_sessions", schema: "public")
private struct SessionSQLRow {
    @Column("token_hash", primaryKey: true) var tokenHash: Data
    @Column("user_id") var userID: UUID
    @Column("credential_id") var credentialID: Data
    var origin: String
    @Column("created_at") var createdAt: Date
    @Column("expires_at") var expiresAt: Date
    @Column("revoked_at") var revokedAt: Date?
}

/// Uses the requested PostgreSQL/PostgresNIO trait binding adapter while keeping
/// execution async on the existing borrowed connection/transaction. Never nest a
/// synchronous Database.read/write lease inside an authentication transaction.
enum AuthTypedQueries {
    static func credentialAvailability(id: Data) throws -> PostgresQuery {
        let query = CredentialSQLRow.where { $0.id.eq(id) }.select { $0.id.count() }.query
        return try compile(query)
    }

    static func credentialForAuthentication(id: Data) throws -> PostgresQuery {
        var query = CredentialSQLRow
            .where { $0.id.eq(id) }
            .where { #sql("\($0.revokedAt) IS NULL", as: Bool.self) }
            .select { ($0.userID, $0.userHandle, $0.publicKeyCOSE, $0.signCount, $0.backupEligible) }
            .query
        // Static clause; this lock remains inside the caller's transaction.
        query.append(" FOR UPDATE")
        return try compile(query)
    }

    static func sessionLookup(tokenHash: Data, origin: String) throws -> PostgresQuery {
        var query = SessionSQLRow
            .where { $0.tokenHash.eq(tokenHash) }
            .where { $0.origin.eq(origin) }
            .select { ($0.userID, $0.expiresAt) }
            .query
        // Security predicates stay in this same statement. The subquery is a
        // fixed fragment; all caller values above are separately bound values.
        query.append("""
             AND "auth_sessions"."revoked_at" IS NULL
             AND "auth_sessions"."created_at" <= clock_timestamp()
             AND "auth_sessions"."expires_at" > clock_timestamp()
             AND EXISTS (
                 SELECT 1 FROM public.passkey_credentials AS c
                 WHERE c.user_id="auth_sessions"."user_id"
                   AND c.id="auth_sessions"."credential_id" AND c.revoked_at IS NULL
             )
            """)
        return try compile(query)
    }

    static func revokeSession(tokenHash: Data, origin: String) throws -> PostgresQuery {
        let query = SessionSQLRow
            .update { $0.revokedAt = #sql("clock_timestamp()", as: Date?.self) }
            .where { $0.tokenHash.eq(tokenHash) }
            .where { $0.origin.eq(origin) }
            .where { #sql("\($0.revokedAt) IS NULL", as: Bool.self) }
            .query
        return try compile(query)
    }

    static func revokeAllSessions(userID: UUID) throws -> PostgresQuery {
        let query = SessionSQLRow
            .update { $0.revokedAt = #sql("clock_timestamp()", as: Date?.self) }
            .where { $0.userID.eq(userID) }
            .where { #sql("\($0.revokedAt) IS NULL", as: Bool.self) }
            .query
        return try compile(query)
    }

    private static func compile(_ query: ISO_9075.Fragment) throws -> PostgresQuery {
        do {
            // This initializer is supplied by swift-postgresql's PostgresNIO
            // trait: SQL text and values remain separate through driver binding.
            return try PostgresQuery(PostgreSQL().render(query))
        } catch {
            // ISO_9075 binding errors can contain input material. Never describe
            // the raw error, query, Rendering.values or driver bindings.
            throw AuthenticationError.unavailable
        }
    }
}
