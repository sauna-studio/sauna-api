import SaunaAPIDatabase
import Testing

struct ProductConditionsTests {
    @Test(arguments: ProductKind.allCases)
    func fourKindsAcceptConfiguredConditionsWithoutBusinessDefaults(_ kind: ProductKind) throws {
        let overnight = kind == .overnightTent
        let value = try ProductConditions(kind: kind, capacity: 6, minimumDurationMinutes: 30,
            maximumDurationMinutes: 300, minimumNights: overnight ? 1 : 0, maximumNights: overnight ? 3 : 0)
        #expect(value.capacity == 6)
        #expect(value.maximumDurationMinutes == 300)
        #expect(value.minimumNights == (overnight ? 1 : 0))
    }
    @Test func invalidCountsIntervalsAndNightKindsAreRejected() {
        let invalid = [
            (ProductKind.privateSauna,0,1,1,0,0), (.sharedSauna,Int.max,1,1,0,0),
            (.dayTent,1,0,1,0,0), (.privateSauna,1,3,2,0,0),
            (.privateSauna,1,1,Int.max,0,0), (.dayTent,1,1,1,1,1),
            (.overnightTent,1,1,1,0,1), (.overnightTent,1,1,1,3,2),
            (.overnightTent,1,1,1,1,Int.max), (.overnightTent,1,1,1,-1,1),
        ]
        for value in invalid {
            #expect(throws: FacilityStoreError.invalidInput) {
                try ProductConditions(kind: value.0, capacity: value.1, minimumDurationMinutes: value.2,
                    maximumDurationMinutes: value.3, minimumNights: value.4, maximumNights: value.5)
            }
        }
    }
}
