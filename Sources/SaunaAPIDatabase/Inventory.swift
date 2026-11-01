public import Foundation

public enum InventoryError: Error, Equatable, CustomStringConvertible {
    case invalidInput, notAvailable, conflict, unavailable
    public var description: String {
        switch self {
        case .invalidInput: "The inventory input is invalid."
        case .notAvailable: "The inventory resource is not available."
        case .conflict: "The inventory operation conflicts with an existing allocation."
        case .unavailable: "The inventory service is unavailable."
        }
    }
}

public enum InventoryResourceKind: String, Sendable {
    case sauna, tent
}

public struct InventoryInterval: Sendable, Equatable {
    public let startsAt: Date
    public let endsAt: Date
    public init(startsAt: Date, endsAt: Date) throws {
        // PostgresNIO converts epoch-2000 microseconds directly to Int64. Check
        // PostgreSQL 18's native timestamp bounds before that nonthrowing cast.
        let epoch = Date(timeIntervalSince1970: 946_684_800)
        let lower = startsAt.timeIntervalSince(epoch) * 1_000_000
        let upper = endsAt.timeIntervalSince(epoch) * 1_000_000
        guard lower.isFinite, upper.isFinite,
              lower >= -211_813_488_000_000_000, upper < 9_223_371_331_200_000_000,
              lower < upper, Int64(lower) < Int64(upper) else { throw InventoryError.invalidInput }
        self.startsAt = startsAt
        self.endsAt = endsAt
    }
}

public enum InventorySeats: Sendable, Equatable {
    case wholeResource
    case sharedSeat(Int)
}

public struct InventoryResource: Sendable, Equatable {
    public let facilityID: UUID
    public let id: UUID
    public let kind: InventoryResourceKind
    public let name: String
    public let capacity: Int
    public let enabled: Bool
}

public struct InventoryClaim: Sendable, Equatable {
    public let facilityID: UUID
    public let id: UUID
    public let productID: UUID
    public let productKind: ProductKind
    public let resourceID: UUID
    public let capacity: Int
    public let interval: InventoryInterval
    public let seats: InventorySeats
    public let releasedAt: Date?
}
