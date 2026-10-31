import Foundation
import Testing
@testable import SaunaAPIIdentity

struct AuthenticationErrorTests {
    @Test func challengeFailuresPreserveAvailabilityClassification() {
        let invalid = authError(PasskeyChallengeError.invalidInput) as? AuthenticationError
        let missing = authError(PasskeyChallengeError.notAvailable) as? AuthenticationError
        let unavailable = authError(PasskeyChallengeError.unavailable) as? AuthenticationError
        #expect(invalid == .invalidInput)
        #expect(missing == .rejected)
        #expect(unavailable == .unavailable)
    }
    @Test func base64URLReplacesLiteralAlphabetAndCanonicalPadding() throws {
        let vectors: [([UInt8], String)] = [([0xfb], "-w"), ([0xfb, 0xff], "-_8"), ([0xfb, 0xff, 0xff], "-___")]
        for (bytes, expected) in vectors {
            let value = Data(bytes)
            #expect(authEncode(value) == expected)
            #expect(try authDecode(expected) == value)
        }
        #expect(throws: AuthenticationError.invalidInput) { try authDecode("-w==") }
    }

}
