import Foundation
import SaunaAPIDatabase
import Testing

struct InventoryIntervalTests {
    @Test func finiteOrderedIntervalsPreserveTheirExactEndpoints() throws {
        let starts = Date(timeIntervalSinceReferenceDate: -63_072_000.25)
        let ends = starts.addingTimeInterval(60)
        let value = try InventoryInterval(startsAt: starts, endsAt: ends)
        #expect(value.startsAt == starts)
        #expect(value.endsAt == ends)
        let adjacent = try InventoryInterval(startsAt: ends, endsAt: ends.addingTimeInterval(60))
        #expect(value.endsAt == adjacent.startsAt)
    }

    @Test func nonfiniteEmptyAndReversedIntervalsAreRejected() {
        let finite = Date(timeIntervalSinceReferenceDate: 0)
        let invalid: [(Date, Date)] = [
            (finite, finite), (finite.addingTimeInterval(1), finite),
            (Date(timeIntervalSinceReferenceDate: .nan), finite),
            (finite, Date(timeIntervalSinceReferenceDate: .nan)),
            (Date(timeIntervalSinceReferenceDate: -.infinity), finite),
            (finite, Date(timeIntervalSinceReferenceDate: .infinity)),
        ]
        for (starts, ends) in invalid {
            #expect(throws: InventoryError.invalidInput) {
                try InventoryInterval(startsAt: starts, endsAt: ends)
            }
        }
    }

    @Test func finiteDatesOutsidePostgreSQLStorageAreRejectedWithoutIntegerConversion() {
        let ordinary = Date(timeIntervalSince1970: 0)
        let outside: [(Date, Date)] = [
            (Date(timeIntervalSince1970: -1_000_000_000_000), ordinary),
            (ordinary, Date(timeIntervalSince1970: 10_000_000_000_000)),
            (ordinary, Date(timeIntervalSince1970: 1e25)),
        ]
        for (starts, ends) in outside {
            #expect(throws: InventoryError.invalidInput) {
                try InventoryInterval(startsAt: starts, endsAt: ends)
            }
        }
    }

    @Test func distinctEndpointsThatCollapseToOneDatabaseMicrosecondAreRejected() {
        let starts = Date(timeIntervalSinceReferenceDate: 0.0000001)
        let ends = Date(timeIntervalSinceReferenceDate: 0.0000002)
        #expect(starts < ends)
        #expect(throws: InventoryError.invalidInput) {
            try InventoryInterval(startsAt: starts, endsAt: ends)
        }
    }
}
