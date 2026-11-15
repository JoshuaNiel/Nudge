import Foundation
import Supabase

// MARK: - Write models

/// Insert payload for `app_category`. `selection` is the base64 PropertyList
/// `FamilyActivitySelection` (`SelectionCodec`, G1).
struct AppCategoryInsert: Encodable {
    let userId: UUID
    let name: String
    let color: String
    let selection: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case name
        case color
        case selection
    }
}

/// Update payload: owner is never rewritten.
struct AppCategoryUpdate: Encodable {
    let name: String
    let color: String
    let selection: String

    enum CodingKeys: String, CodingKey {
        case name
        case color
        case selection
    }
}

// MARK: - Protocol

/// Categories are picker selections stored on `app_category.selection` (G10). The
/// deprecated `app_category_member` table is no longer read or written.
protocol CategoryServiceProtocol {
    func fetchCategories(userId: UUID) async throws -> [AppCategory]
    func createCategory(userId: UUID, name: String, color: String, selection: String) async throws -> AppCategory
    func updateCategory(id: Int, userId: UUID, name: String, color: String, selection: String) async throws -> AppCategory
    /// Goals using the category are removed by the DB (`on delete cascade`).
    func deleteCategory(id: Int, userId: UUID) async throws
}

// MARK: - Service

/// Every query is scoped to `user_id` in addition to RLS (defense in depth).
@MainActor
final class CategoryService: CategoryServiceProtocol {

    func fetchCategories(userId: UUID) async throws -> [AppCategory] {
        try await supabase
            .from("app_category")
            .select()
            .eq("user_id", value: userId)
            .execute()
            .value
    }

    func createCategory(userId: UUID, name: String, color: String, selection: String) async throws -> AppCategory {
        try await supabase
            .from("app_category")
            .insert(AppCategoryInsert(userId: userId, name: name, color: color, selection: selection))
            .select()
            .single()
            .execute()
            .value
    }

    func updateCategory(id: Int, userId: UUID, name: String, color: String, selection: String) async throws -> AppCategory {
        try await supabase
            .from("app_category")
            .update(AppCategoryUpdate(name: name, color: color, selection: selection))
            .eq("id", value: id)
            .eq("user_id", value: userId)
            .select()
            .single()
            .execute()
            .value
    }

    func deleteCategory(id: Int, userId: UUID) async throws {
        try await supabase
            .from("app_category")
            .delete()
            .eq("id", value: id)
            .eq("user_id", value: userId)
            .execute()
    }
}
