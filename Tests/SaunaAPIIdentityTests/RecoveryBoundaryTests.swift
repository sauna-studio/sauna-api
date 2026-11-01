import Foundation
import PostgresNIO
import Testing
@testable import SaunaAPIIdentity

@Suite(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
struct RecoveryBoundaryTests {
    @Test func aSessionAndAnUnrelatedValidPasskeyCannotAuthorizeCredentialAddition() async throws {
        try await withAuthDatabase { client, records in
            let (owner, _, _) = try await registration(client: client, records: records)
            let (unrelated, _, _) = try await registration(client: client, records: records)
            let login = try PasskeyAuthService(client: client, relyingParty: .customer)
            let management = try PasskeyManagementService(client: client, relyingParty: .customer)
            let sessions = SessionStore(client: client, relyingParty: .customer)
            let grant = try await signedLogin(owner, service: login, records: records, counter: 0)
            let options = try await management.beginAddition(token: grant.token, csrfToken: grant.session.csrfToken)
            let challenge = try authDecode(JSONDecoder().decode(TestOptions.self, from: options.optionsJSON).challenge)
            let foreignAssertion = try unrelated.key.assertion(challenge: challenge, counter: 0, handle: unrelated.handle)

            // Invalid crypto would not establish that the account-ownership boundary rejected this proof.
            let proof = try LivePasskeyVerifier(origin: "http://localhost:5173").verifyAssertion(
                credentialJSON: foreignAssertion, challenge: challenge,
                storedCredential: .init(credentialID: unrelated.key.id, userHandle: unrelated.handle,
                    publicKeyCOSE: unrelated.key.cose, signCount: 0, backupEligible: false))
            let validForeignProof = proof.credentialID == unrelated.key.id
            #expect(validForeignProof)
            await rejected {
                _ = try await management.authorizeAddition(challengeID: options.challengeID,
                    credentialJSON: foreignAssertion, token: grant.token, csrfToken: grant.session.csrfToken)
            }
            let rows = try await client.query("""
                SELECT consumed_at IS NOT NULL, authorization_credential_id IS NULL,
                    authorized_at IS NULL, registration_challenge IS NULL
                FROM public.passkey_management_intents WHERE id=\(options.challengeID)
                """)
            var inspected = false
            for try await (spent, noAuthorizer, noAuthorization, noRegistration) in rows.decode((Bool, Bool, Bool, Bool).self) {
                #expect(spent && noAuthorizer && noAuthorization && noRegistration)
                inspected = true
            }
            #expect(inspected)
            let list = try await management.list(token: grant.token)
            #expect(list.count == 1)
            let unchangedOwner = try await sessions.resolve(token: grant.token).subject.userID == owner.user
            #expect(unchangedOwner)

            // Reusing a spent intent must fail even when the rightful owner supplies a valid proof.
            await rejected {
                _ = try await management.authorizeAddition(challengeID: options.challengeID,
                    credentialJSON: owner.key.assertion(challenge: challenge, counter: 0, handle: owner.handle),
                    token: grant.token, csrfToken: grant.session.csrfToken)
            }
            let fresh = try await management.beginAddition(token: grant.token, csrfToken: grant.session.csrfToken)
            let freshNonce = try authDecode(JSONDecoder().decode(TestOptions.self, from: fresh.optionsJSON).challenge)
            let authorized = try await management.authorizeAddition(challengeID: fresh.challengeID,
                credentialJSON: owner.key.assertion(challenge: freshNonce, counter: 0, handle: owner.handle),
                token: grant.token, csrfToken: grant.session.csrfToken)
            let ownerWasAuthorized = authorized.challengeID == fresh.challengeID
            #expect(ownerWasAuthorized)
        }
    }
}
