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

// MARK: - Friend name

extension String {
    /// `friend.friend_name` is `varchar(100)` with a non-blank check.
    static let friendNameMaxLength = 100

    /// The name as it is stored: surrounding whitespace and newlines removed.
    var trimmedFriendName: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the trimmed name is non-blank and fits the column.
    var isValidFriendName: Bool { friendNameValidationError == nil }

    /// Why the name can't be saved, or nil if it can. Checked after trimming.
    ///
    /// Length is counted in Unicode scalars, the unit Postgres uses for `varchar(n)` in UTF-8,
    /// so a name accepted here is never rejected by the column.
    var friendNameValidationError: String? {
        let name = trimmedFriendName
        if name.isEmpty { return "Name can't be empty." }
        if name.unicodeScalars.count > Self.friendNameMaxLength {
            return "Name must be \(Self.friendNameMaxLength) characters or fewer."
        }
        return nil
    }
}
