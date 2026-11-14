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

extension String {
    /// Pragmatic email format check (`local@domain.tld`, TLD ≥ 2 letters).
    ///
    /// This only catches typos before a network call; Supabase is the authority
    /// on what it accepts. Does not trim — callers trim at submit time.
    var isValidEmail: Bool {
        let pattern = #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}$"#
        return range(of: pattern, options: .regularExpression) != nil
    }
}

/// Client-side rules for choosing a new password.
enum PasswordRules {
    static let minimumLength = 8

    static let tooShortMessage = "Password must be at least \(minimumLength) characters."
    static let mismatchMessage = "Passwords do not match."

    /// The first rule `password` breaks, or `nil` if it is acceptable.
    /// Length is checked before the match so the user fixes one thing at a time.
    /// Passwords are never trimmed — whitespace is a legitimate character.
    static func validationError(password: String, confirmation: String) -> String? {
        if password.count < minimumLength { return tooShortMessage }
        if password != confirmation { return mismatchMessage }
        return nil
    }
}
