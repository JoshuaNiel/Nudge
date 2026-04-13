import Foundation
import Supabase

class CategoryService {

    func fetchCategories(userId: UUID) async throws -> [AppCategory] {
        try await supabase
            .from("app_category")
            .select()
            .eq("user_id", value: userId)
            .execute()
            .value
    }

    func createCategory(userId: UUID, name: String, color: String) async throws -> AppCategory {
        try await supabase
            .from("app_category")
            .insert(["user_id": userId.uuidString, "name": name, "color": color])
            .select()
            .single()
            .execute()
            .value
    }

    func deleteCategory(id: Int) async throws {
        try await supabase
            .from("app_category")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    func addApp(bundleId: String, categoryId: Int) async throws {
        try await supabase
            .from("app_category_member")
            .insert(["bundle_id": bundleId, "category_id": String(categoryId)])
            .execute()
    }

    func removeApp(bundleId: String, categoryId: Int) async throws {
        try await supabase
            .from("app_category_member")
            .delete()
            .eq("bundle_id", value: bundleId)
            .eq("category_id", value: categoryId)
            .execute()
    }

    func fetchMembers(categoryId: Int) async throws -> [String] {
        let members: [AppCategoryMember] = try await supabase
            .from("app_category_member")
            .select()
            .eq("category_id", value: categoryId)
            .execute()
            .value
        return members.map(\.bundleId)
    }
}
