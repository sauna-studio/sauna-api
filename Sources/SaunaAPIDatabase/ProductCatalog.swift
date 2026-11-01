public import Foundation

public enum ProductKind: String, Sendable, CaseIterable {
    case privateSauna = "private_sauna"
    case sharedSauna = "shared_sauna"
    case dayTent = "day_tent"
    case overnightTent = "overnight_tent"
}

public struct ProductConditions: Sendable, Equatable {
    public let kind: ProductKind
    public let capacity: Int
    public let minimumDurationMinutes: Int
    public let maximumDurationMinutes: Int
    public let minimumNights: Int
    public let maximumNights: Int

    public init(kind: ProductKind, capacity: Int, minimumDurationMinutes: Int, maximumDurationMinutes: Int,
                minimumNights: Int, maximumNights: Int) throws {
        let maximum = Int(Int32.max)
        guard (1...maximum).contains(capacity), (1...maximum).contains(minimumDurationMinutes),
              (minimumDurationMinutes...maximum).contains(maximumDurationMinutes),
              (0...maximum).contains(minimumNights), (minimumNights...maximum).contains(maximumNights) else {
            throw FacilityStoreError.invalidInput
        }
        switch kind {
        case .overnightTent:
            guard minimumNights > 0 else { throw FacilityStoreError.invalidInput }
        case .privateSauna, .sharedSauna, .dayTent:
            guard minimumNights == 0, maximumNights == 0 else { throw FacilityStoreError.invalidInput }
        }
        self.kind = kind
        self.capacity = capacity
        self.minimumDurationMinutes = minimumDurationMinutes
        self.maximumDurationMinutes = maximumDurationMinutes
        self.minimumNights = minimumNights
        self.maximumNights = maximumNights
    }
}

public struct CatalogProduct: Sendable, Equatable {
    public let facilityID: UUID
    public let id: UUID
    public let name: String
    public let published: Bool
    public let conditions: ProductConditions
}
