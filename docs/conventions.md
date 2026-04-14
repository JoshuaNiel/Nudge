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

    private let service: MyServiceProtocol

    // Production init — no default parameter (see below)
    init() { self.service = MyService() }

    // Testing init — inject a mock
    init(service: MyServiceProtocol) { self.service = service }

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

**Important — two-init pattern required with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`:**

Do NOT write a single init with a default parameter value:
```swift
// WRONG — produces "Call to main actor-isolated initializer in a synchronous nonisolated context"
init(service: MyServiceProtocol = MyService()) { ... }
```

Use two separate inits instead: a no-argument production init and an explicit injection init for tests. This is because the default expression (`MyService()`) is evaluated in a nonisolated context when the parameter is defaulted, which violates the `@MainActor` isolation of `MyService.init()`.

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

## Testing

### Test-First Pattern

For every new feature, write tests **before** implementing. The cycle:

1. Write tests that cover the contract (model coding, business logic, computed properties)
2. Run — all new tests should fail
3. Implement until all tests pass
4. Run again to confirm no regressions

### Test File Location

All tests live in `NudgeTests/feature.swift`. The structure should mimic the normal repo strucutre.

### Running Tests (CLI)

```bash
xcodebuild test \
  -project Nudge.xcodeproj \
  -scheme Nudge \
  -destination 'platform=iOS Simulator,arch=arm64,id=19C7BD9B-6973-4F63-8492-C8D13401B835'
```

Filter to a single suite: append `-only-testing:NudgeTests/GoalCodingTests`

### What to Test

| Category | What | How |
|---|---|---|
| Model decoding | Decode from snake_case JSON (as Supabase returns) — verify all properties | `JSONDecoder` + literal JSON string |
| Model encoding | Encode to JSON — snake_case keys present, camelCase absent | `JSONEncoder` + `JSONSerialization` key check |
| Enum raw values | Each case matches the DB enum string exactly | `#expect(MyEnum.case.rawValue == "db_string")` |
| Computed properties | Boundary values for `progressFraction`, `isExceeded`, etc. | Direct struct init, no mocking needed |
| Formatters | `formattedDuration` and any display helpers | Direct call on known inputs |
| Service behavior | Correct args passed, returned data flows to ViewModel state | Mock service conforming to service protocol (see below) |
| ViewModel loading state | `isLoading` true during fetch, false after; `error` set on throw | Inject slow/throwing mock, check `@Published` state |
| Input validation | Error message set and early return on invalid input | Call action method directly on view or ViewModel |

---

### Service Protocols and Mocking

Services are not tested against real Supabase — that would require a live network and seed data. Instead:

- Each service has a **protocol** listing its `async throws` methods
- The real service conforms to the protocol
- Tests inject a **mock** that conforms to the same protocol

**Define a protocol alongside each service:**

```swift
// GoalService.swift
protocol GoalServiceProtocol {
    func fetchGoals(userId: UUID) async throws -> [Goal]
    func createGoal(_ goal: GoalInsert) async throws
    func deleteGoal(id: Int, userId: UUID) async throws
}

@MainActor
class GoalService: GoalServiceProtocol { ... }
```

**ViewModel accepts the protocol, defaults to the real service:**

```swift
class GoalsViewModel: ObservableObject {
    private let goalService: GoalServiceProtocol
    private let evaluationService: GoalEvaluationServiceProtocol

    init(
        goalService: GoalServiceProtocol = GoalService(),
        evaluationService: GoalEvaluationServiceProtocol = GoalEvaluationService()
    ) {
        self.goalService = goalService
        self.evaluationService = evaluationService
    }
    ...
}
```

**Mock in the test file (not a separate file — keep it local to the suite):**

```swift
private final class MockGoalService: GoalServiceProtocol {
    var goalsToReturn: [Goal] = []
    var errorToThrow: Error? = nil
    var deletedIds: [Int] = []

    func fetchGoals(userId: UUID) async throws -> [Goal] {
        if let error = errorToThrow { throw error }
        return goalsToReturn
    }

    func createGoal(_ goal: GoalInsert) async throws {
        if let error = errorToThrow { throw error }
    }

    func deleteGoal(id: Int, userId: UUID) async throws {
        if let error = errorToThrow { throw error }
        deletedIds.append(id)
    }
}
```

**What to test with mocks:**

```swift
@Suite("GoalsViewModel")
@MainActor
struct GoalsViewModelTests {

    @Test func loadsGoalsIntoState() async throws {
        let mock = MockGoalService()
        mock.goalsToReturn = [/* test goals */]
        let vm = GoalsViewModel(goalService: mock)

        await vm.load(userId: UUID())

        #expect(vm.goals.count == mock.goalsToReturn.count)
        #expect(vm.isLoading == false)
        #expect(vm.error == nil)
    }

    @Test func setsErrorOnServiceFailure() async throws {
        let mock = MockGoalService()
        mock.errorToThrow = URLError(.notConnectedToInternet)
        let vm = GoalsViewModel(goalService: mock)

        await vm.load(userId: UUID())

        #expect(vm.error != nil)
        #expect(vm.goals.isEmpty)
    }

    @Test func deleteRemovesGoalFromState() async throws {
        let mock = MockGoalService()
        let goal = /* test goal */
        mock.goalsToReturn = [goal]
        let vm = GoalsViewModel(goalService: mock)
        await vm.load(userId: UUID())

        await vm.deleteGoal(goal.goal, userId: UUID())

        #expect(vm.goals.isEmpty)
        #expect(mock.deletedIds == [goal.id])
    }
}
```

**Rules:**
- Mock classes are `private final class`, defined inside the test file that uses them — never in production code.
- Mocks capture call arguments (e.g., `deletedIds`) so tests can assert the service was called correctly.
- Do not test that the real service calls the right Supabase table — that is covered by the CodingKeys encode/decode tests plus end-to-end manual testing.

### Test File Conventions

```swift
import Testing
import Foundation
@testable import Nudge

@Suite("Feature Name")
@MainActor                          // required: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
struct FeatureTests {

    @Test func specificBehavior() throws {
        #expect(value == expected)
    }
}
```

- `@MainActor` is required on every `@Suite` struct — the project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes models `@MainActor`, and omitting this annotation produces actor-isolation warnings.
- Use `throws` on test functions that call `JSONDecoder.decode` or `JSONEncoder.encode`.
- Use `#expect(...)` not `XCTAssert*` — this project uses Swift Testing, not XCTest.

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
