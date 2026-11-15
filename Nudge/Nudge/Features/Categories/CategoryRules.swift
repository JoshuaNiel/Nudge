import Foundation
import FamilyControls

/// The 8 preset category colors (G10). Values satisfy the DB check
/// `app_category_color_hex` (`^#[0-9A-Fa-f]{6}$`).
enum CategoryPalette {
    static let colors: [String] = [
        "#FF3B30", // red
        "#FF9500", // orange
        "#FFCC00", // yellow
        "#34C759", // green
        "#00C7BE", // mint
        "#007AFF", // blue
        "#5856D6", // indigo
        "#AF52DE", // purple
    ]

    static let defaultColor = "#007AFF"

    static func isValidHex(_ hex: String) -> Bool {
        hex.wholeMatch(of: /#[0-9A-Fa-f]{6}/) != nil
    }

    /// Accessibility names, index-aligned with `colors`.
    static func name(for hex: String) -> String {
        let names = ["Red", "Orange", "Yellow", "Green", "Mint", "Blue", "Indigo", "Purple"]
        guard let index = colors.firstIndex(of: hex.uppercased()) else { return "Custom color" }
        return names[index]
    }
}

/// Pure category rules (G10), unit-tested in NudgeTests/GoalsUITests.swift.
enum CategoryRules {

    /// `app_category.name` is `varchar(100)`.
    static let nameMaxLength = 100

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func nameError(_ name: String) -> String? {
        let trimmed = normalizedName(name)
        if trimmed.isEmpty { return "Enter a name." }
        if trimmed.count > nameMaxLength { return "Name must be 100 characters or fewer." }
        return nil
    }

    /// A category needs ≥1 app or Apple-category token. Websites alone are not enough:
    /// they may be included alongside, but the category must name some apps.
    static func selectionError(applicationCount: Int, categoryCount: Int, webDomainCount: Int) -> String? {
        applicationCount + categoryCount == 0 ? "Choose at least one app or category." : nil
    }

    static func selectionError(for selection: FamilyActivitySelection) -> String? {
        selectionError(
            applicationCount: selection.applicationTokens.count,
            categoryCount: selection.categoryTokens.count,
            webDomainCount: selection.webDomainTokens.count
        )
    }

    /// "3 apps, 1 category" (+ ", 2 websites" only when there are any).
    static func summaryText(applicationCount: Int, categoryCount: Int, webDomainCount: Int = 0) -> String {
        var parts = [
            plural(applicationCount, "app", "apps"),
            plural(categoryCount, "category", "categories"),
        ]
        if webDomainCount > 0 { parts.append(plural(webDomainCount, "website", "websites")) }
        return parts.joined(separator: ", ")
    }

    static func summaryText(for selection: FamilyActivitySelection) -> String {
        summaryText(
            applicationCount: selection.applicationTokens.count,
            categoryCount: selection.categoryTokens.count,
            webDomainCount: selection.webDomainTokens.count
        )
    }

    /// "—" when the stored selection is missing or undecodable.
    static func summaryText(encodedSelection: String?) -> String {
        guard let encodedSelection, let selection = SelectionCodec.decode(encodedSelection) else { return "—" }
        return summaryText(for: selection)
    }

    private static func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}
