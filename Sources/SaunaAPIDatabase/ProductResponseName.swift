import Foundation

// Trimming a response would silently change the persisted business value.
func validateProductResponseName(_ name: String) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          name.unicodeScalars.count <= 200 else { throw FacilityStoreError.unavailable }
}
