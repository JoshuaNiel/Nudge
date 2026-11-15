import Foundation
import FamilyControls
import ManagedSettings

/// Converts a `FamilyActivitySelection` to and from the base64 string stored in
/// `goal.selection` / `app_category.selection` (Phase 3 G1).
///
/// Format: `PropertyListEncoder` output, base64-encoded. Every failure returns `nil`
/// instead of throwing or trapping — a selection can come from another device or an
/// older OS whose tokens no longer decode, and that must never crash the app or the
/// monitor extension. Callers treat `nil` as "re-select required".
enum SelectionCodec {

    static func encode(_ selection: FamilyActivitySelection) -> String? {
        guard let data = try? PropertyListEncoder().encode(selection) else { return nil }
        return data.base64EncodedString()
    }

    static func decode(_ base64: String) -> FamilyActivitySelection? {
        guard let data = data(fromBase64: base64) else { return nil }
        return decode(data: data)
    }

    static func decode(data: Data) -> FamilyActivitySelection? {
        guard !data.isEmpty else { return nil }
        return try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    /// The raw PropertyList bytes carried in `GoalSummary.selectionData`.
    static func data(fromBase64 base64: String) -> Data? {
        guard !base64.isEmpty, let data = Data(base64Encoded: base64), !data.isEmpty else { return nil }
        return data
    }

    /// A selection with no tokens. Monitoring one would mean "all usage", so app and
    /// category goals with an empty selection are treated like undecodable ones.
    static func isEmpty(_ selection: FamilyActivitySelection) -> Bool {
        selection.applicationTokens.isEmpty
            && selection.categoryTokens.isEmpty
            && selection.webDomainTokens.isEmpty
    }
}
