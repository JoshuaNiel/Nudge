import Foundation

extension String {
    /// True when the string is a valid E.164 phone number (e.g. `+18015551234`).
    var isValidE164: Bool {
        let pattern = #"^\+[1-9]\d{7,14}$"#
        return range(of: pattern, options: .regularExpression) != nil
    }

    /// Specific E.164 validation error, or nil if valid or empty.
    var e164ValidationError: String? {
        let s = trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if !s.hasPrefix("+") { return "Phone number must start with + and your country code (e.g. +1)." }
        let digits = s.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else {
            return "Phone number can only contain digits after the +."
        }
        if digits.first == "0" { return "Country code can't start with 0." }
        if digits.count < 8 { return "Phone number is too short." }
        if digits.count > 15 { return "Phone number is too long." }
        return nil
    }
}
