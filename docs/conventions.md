# Code Conventions

Patterns established in the existing codebase. Follow these when adding new code.

---

## Async / Loading / Error Pattern

Every async action in a view follows this exact structure:

```swift
@State private var isLoading = false
@State private var errorMessage: String? = nil

private func submit() {
    isLoading = true
    Task {
        defer { isLoading = false }
        do {
            try await someService.doSomething()
            onCompleted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- `defer { isLoading = false }` — always used so loading resets on both success and failure
- Errors surface as `error.localizedDescription` into `errorMessage: String?`
- `errorMessage` is displayed inline as `.font(.footnote).foregroundStyle(.red)`, not as an alert
- Reset `errorMessage = nil` before retrying (at the top of the action function)

---

## Primary Button Style

All full-width primary action buttons use this style:

```swift
Button(action: submit) {
    Group {
        if isLoading {
            ProgressView()
        } else {
            Text("Continue")
                .fontWeight(.semibold)
        }
    }
    .frame(maxWidth: .infinity)
    .padding()
    .background(isDisabled ? Color.secondary : Color.accentColor)
    .foregroundStyle(.white)
    .clipShape(RoundedRectangle(cornerRadius: 14))
}
.disabled(isDisabled || isLoading)
.padding(.horizontal, 24)
```

- `ProgressView()` replaces button text while loading — same frame, no layout shift
- Background switches to `Color.secondary` when disabled
- Always `.disabled(isLoading)` in addition to any other disable condition

---

## View Structure

Views are split into two blocks: the struct (body + private state) and an extension (action methods).

```swift
struct MyView: View {
    // 1. Callbacks (var, no default)
    var onCompleted: () -> Void

    // 2. Environment
    @EnvironmentObject private var appState: AppState

    // 3. Local state
    @State private var value = ""
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    // 4. Private enums scoped to this view
    private enum Mode { case a, b }

    var body: some View { ... }

    // MARK: - Previews (inline, before extension)
}

#Preview { MyView(onCompleted: {}).environmentObject(AppState()) }

extension MyView {
    // MARK: - Section Name
    private func actionMethod() { ... }
}
```

- Logic lives in the `extension`, not in `body`
- `// MARK: - Section Name` used to organize extension blocks
- `@EnvironmentObject` is always `private`
- Previews go between the struct closing brace and the extension

---

## View Navigation / Callbacks

Views do not own their navigation. They receive callbacks and call them when done.

```swift
// Correct
struct MyView: View {
    var onCompleted: () -> Void
    ...
    // calls onCompleted() when done
}

// Wrong — views do not push/pop or own NavigationStack internally
```

Parent views (coordinators) hold step state and wire callbacks:

```swift
switch step {
case .first: FirstView(onCompleted: { step = .second })
case .second: SecondView(onCompleted: { step = .third })
}
```

---

## ViewModels

Use a ViewModel (`@MainActor class`, `ObservableObject`) when a view has:
- Data fetched from Supabase
- Multiple related pieces of state that change together
- Logic beyond simple form validation

Simple forms and onboarding steps can hold state directly in the view.

ViewModel pattern:
```swift
@MainActor
class MyFeatureViewModel: ObservableObject {
    @Published var items: [Item] = []
    @Published var isLoading = false
    @Published var error: String? = nil

    private let service = MyService()

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await service.fetchItems()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

Instantiated in the view as `@StateObject`.

ViewModel files must `import Combine` — `ObservableObject` and `@Published` require it.

---

## Services

- All service files that make Supabase calls must `import Supabase` — without it, `.from()`, `.eq()`, `.execute()`, `.value` etc. will fail to compile
- All Supabase calls go in a service class, never directly in a view or ViewModel
- Services are `@MainActor` classes with `async throws` methods
- No state — services are stateless; state lives in AppState or ViewModels
- Errors are not caught in services — let them propagate to the caller

```swift
@MainActor
class MyService {
    func fetchItems() async throws -> [Item] {
        try await supabase
            .from("my_table")
            .select()
            .eq("user_id", value: userId)
            .execute()
            .value
    }
}
```

---

## Models

- Plain `struct`, `Codable`, `Identifiable`
- Property names are camelCase — Supabase Swift SDK auto-converts from snake_case
- Always use explicit `CodingKeys` with snake_case string values for any model that is read from or written to Supabase. Do not rely on automatic `convertFromSnakeCase` — it is not consistently applied across SDK versions and produces silent decoding failures. Both `Encodable` insert structs and `Codable` read models need explicit keys.
- Enums for DB enum columns: `String`, `Codable`, cases match the DB enum values exactly

```swift
struct MyModel: Codable, Identifiable {
    let id: Int
    let userId: UUID       // DB: user_id
    let someValue: String  // DB: some_value
}

enum MyStatus: String, Codable {
    case pendingReview = "pending_review"  // match DB enum value exactly
    case active
}
```

---

## Input Handling

- Trim whitespace at save time, not while the user types: `value.trimmingCharacters(in: .whitespaces)`
- Validate before async calls; set `errorMessage` and return early if invalid
- Phone numbers must be validated as E.164 (`^\+[1-9]\d{7,14}$`) before saving

---

## Spacing & Layout Constants

Consistent values used throughout:

| Use | Value |
|---|---|
| Horizontal content padding | `.padding(.horizontal, 24)` |
| Bottom safe area padding | `.padding(.bottom, 40)` |
| Vertical spacing between major sections | `VStack(spacing: 28)` |
| Vertical spacing within a field group | `VStack(spacing: 12)` |
| Vertical spacing in a header | `VStack(spacing: 8)` |
| Button corner radius | `14` |
