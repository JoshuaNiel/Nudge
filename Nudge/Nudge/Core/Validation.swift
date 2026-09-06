import Foundation

extension String {
    /// True when the string is a valid E.164 phone number (e.g. `+18015551234`).
    var isValidE164: Bool {
        let pattern = #"^\+[1-9]\d{7,14}$"#
        return range(of: pattern, options: .regularExpression) != nil
    }
}
