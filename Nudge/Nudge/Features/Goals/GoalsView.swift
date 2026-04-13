import SwiftUI
import Supabase

// MARK: - GoalsView

struct GoalsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = GoalsViewModel()
    @State private var showAddGoal = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = viewModel.error {
                    errorView(message: errorMessage)
                } else if viewModel.goals.isEmpty {
                    emptyState
                } else {
                    goalList
                }
            }
            .navigationTitle("Goals")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddGoal = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddGoal) {
                AddGoalSheet {
                    showAddGoal = false
                    guard let userId = appState.currentUser?.id else { return }
                    Task { await viewModel.load(userId: userId) }
                }
                .environmentObject(appState)
            }
            .task {
                guard let userId = appState.currentUser?.id else { return }
                await viewModel.load(userId: userId)
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "target")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No goals yet")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Tap + to create your first goal.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var goalList: some View {
        List {
            ForEach(viewModel.goals) { item in
                GoalRow(item: item)
            }
            .onDelete { indexSet in
                deleteGoals(at: indexSet)
            }
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Something went wrong")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Previews

#Preview {
    GoalsView()
        .environmentObject(AppState())
}

// MARK: - Actions

extension GoalsView {
    private func deleteGoals(at offsets: IndexSet) {
        guard let userId = appState.currentUser?.id else { return }
        for index in offsets {
            let item = viewModel.goals[index]
            Task { await viewModel.deleteGoal(item.goal, userId: userId) }
        }
    }
}

// MARK: - GoalRow

private struct GoalRow: View {
    let item: GoalWithProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(targetLabel)
                    .font(.headline)
                Spacer()
                Text(item.goal.frequency.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: item.progressFraction)
                .tint(item.isExceeded ? .red : .accentColor)
            Text(timeLabel)
                .font(.caption)
                .foregroundStyle(item.isExceeded ? .red : .secondary)
        }
        .padding(.vertical, 4)
    }

    private var targetLabel: String {
        switch item.goal.targetType {
        case .total:    return "All Apps"
        case .app:      return item.goal.bundleId ?? "Unknown App"
        case .category: return item.goal.categoryId.map { "Category \($0)" } ?? "Unknown Category"
        }
    }

    private var timeLabel: String {
        "\(item.usedSeconds.formattedDuration) / \(item.goal.limitSeconds.formattedDuration)"
    }
}

// MARK: - GoalFrequency display

private extension GoalFrequency {
    var displayName: String {
        switch self {
        case .daily:   return "Daily"
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}

// MARK: - AddGoalSheet

private enum GoalDuration { case permanent, temporary }

private struct AddGoalSheet: View {
    var onCompleted: () -> Void

    @EnvironmentObject private var appState: AppState

    private enum Step { case targetType, targetPicker, limitAndFrequency }

    @State private var step: Step = .targetType
    @State private var selectedTargetType: GoalTargetType? = nil
    @State private var selectedBundleId: String? = nil
    @State private var selectedCategoryId: Int? = nil
    @State private var limitHours = 1
    @State private var limitMinutes = 0
    @State private var selectedFrequency: GoalFrequency = .daily
    @State private var goalDuration: GoalDuration = .permanent
    @State private var startDate = Date()
    @State private var endDate = Date().addingTimeInterval(7 * 24 * 3600)
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch step {
                case .targetType:
                    TargetTypeStep { type in
                        selectedTargetType = type
                        step = type == .total ? .limitAndFrequency : .targetPicker
                    }
                case .targetPicker:
                    TargetPickerStep(
                        targetType: selectedTargetType ?? .app,
                        selectedBundleId: $selectedBundleId,
                        selectedCategoryId: $selectedCategoryId,
                        onNext: { step = .limitAndFrequency }
                    )
                    .environmentObject(appState)
                case .limitAndFrequency:
                    LimitAndFrequencyStep(
                        hours: $limitHours,
                        minutes: $limitMinutes,
                        frequency: $selectedFrequency,
                        goalDuration: $goalDuration,
                        startDate: $startDate,
                        endDate: $endDate,
                        isLoading: isLoading,
                        errorMessage: errorMessage,
                        onConfirm: confirm
                    )
                }
            }
            .navigationTitle(stepTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step == .targetType {
                        Button("Cancel") { onCompleted() }
                    } else {
                        Button(action: goBack) {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
            }
        }
    }

    private var stepTitle: String {
        switch step {
        case .targetType:          return "Choose Target"
        case .targetPicker:        return selectedTargetType == .app ? "Pick App" : "Pick Category"
        case .limitAndFrequency:   return "Set Limit"
        }
    }
}

#Preview("Add Goal") {
    Color.clear.sheet(isPresented: .constant(true)) {
        AddGoalSheet(onCompleted: {})
            .environmentObject(AppState())
    }
}

extension AddGoalSheet {

    // MARK: - Navigation

    private func goBack() {
        switch step {
        case .targetType:          break
        case .targetPicker:        step = .targetType
        case .limitAndFrequency:   step = selectedTargetType == .total ? .targetType : .targetPicker
        }
    }

    // MARK: - Submit

    private func confirm() {
        guard let userId = appState.currentUser?.id,
              let targetType = selectedTargetType else { return }

        let totalSeconds = (limitHours * 3600) + (limitMinutes * 60)
        guard totalSeconds > 0 else {
            errorMessage = "Limit must be greater than zero."
            return
        }

        let isTemporary = goalDuration == .temporary
        let insert = GoalInsert(
            userId: userId,
            limitSeconds: totalSeconds,
            frequency: selectedFrequency,
            targetType: targetType,
            bundleId: targetType == .app ? selectedBundleId : nil,
            categoryId: targetType == .category ? selectedCategoryId : nil,
            temporary: isTemporary,
            startDate: isTemporary ? formatDate(startDate) : nil,
            endDate: isTemporary ? formatDate(endDate) : nil
        )

        errorMessage = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                try await GoalService().createGoal(insert)
                onCompleted()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Step Views

private struct TargetTypeStep: View {
    var onSelected: (GoalTargetType) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("What do you want to limit?")
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.top, 32)
            VStack(spacing: 12) {
                targetButton(label: "Total Usage", subtitle: "All apps combined", type: .total, icon: "iphone")
                targetButton(label: "Specific App", subtitle: "Limit a single app", type: .app, icon: "app.fill")
                targetButton(label: "App Category", subtitle: "Limit a custom group of apps", type: .category, icon: "folder.fill")
            }
            .padding(.horizontal, 24)
            Spacer()
        }
    }

    private func targetButton(label: String, subtitle: String, type: GoalTargetType, icon: String) -> some View {
        Button { onSelected(type) } label: {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 36)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).fontWeight(.semibold)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

private struct TargetPickerStep: View {
    let targetType: GoalTargetType
    @Binding var selectedBundleId: String?
    @Binding var selectedCategoryId: Int?
    var onNext: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var categories: [AppCategory] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    private var isNextEnabled: Bool {
        targetType == .app ? selectedBundleId != nil : selectedCategoryId != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView().padding(.top, 48)
            } else if let error = errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).padding()
            } else if targetType == .category {
                categoryList
            } else {
                appPlaceholder
            }
            Spacer()
            Button(action: onNext) {
                Text("Next")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(!isNextEnabled ? Color.secondary : Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!isNextEnabled)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .task { await loadCategories() }
    }

    private var appPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "app.dashed")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .padding(.top, 40)
            Text("App picker coming soon")
                .foregroundStyle(.secondary)
            Text("Enter bundle ID manually:")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("com.example.app", text: Binding(
                get: { selectedBundleId ?? "" },
                set: { selectedBundleId = $0.isEmpty ? nil : $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 24)
        }
    }

    private var categoryList: some View {
        List(categories) { category in
            HStack {
                Circle()
                    .fill(Color(hex: category.color) ?? Color.accentColor)
                    .frame(width: 14, height: 14)
                Text(category.name)
                Spacer()
                if selectedCategoryId == category.id {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { selectedCategoryId = category.id }
        }
    }

    private func loadCategories() async {
        guard targetType == .category, let userId = appState.currentUser?.id else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            categories = try await CategoryService().fetchCategories(userId: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct LimitAndFrequencyStep: View {
    @Binding var hours: Int
    @Binding var minutes: Int
    @Binding var frequency: GoalFrequency
    @Binding var goalDuration: GoalDuration
    @Binding var startDate: Date
    @Binding var endDate: Date
    let isLoading: Bool
    let errorMessage: String?
    var onConfirm: () -> Void

    private var isLimitSet: Bool { hours > 0 || minutes > 0 }
    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {

                // Frequency
                VStack(alignment: .leading, spacing: 8) {
                    Text("Resets").font(.headline).padding(.horizontal, 24)
                    Picker("Frequency", selection: $frequency) {
                        Text("Daily").tag(GoalFrequency.daily)
                        Text("Weekly").tag(GoalFrequency.weekly)
                        Text("Monthly").tag(GoalFrequency.monthly)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 24)
                }

                // Time limit
                VStack(alignment: .leading, spacing: 8) {
                    Text("Time limit").font(.headline).padding(.horizontal, 24)
                    HStack(spacing: 0) {
                        Picker("Hours", selection: $hours) {
                            ForEach(0..<24) { h in Text("\(h)h").tag(h) }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        Picker("Minutes", selection: $minutes) {
                            ForEach([0, 5, 10, 15, 20, 30, 45], id: \.self) { m in Text("\(m)m").tag(m) }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                    }
                }

                // Duration
                VStack(alignment: .leading, spacing: 8) {
                    Text("Duration").font(.headline).padding(.horizontal, 24)
                    Picker("Duration", selection: $goalDuration) {
                        Text("Permanent").tag(GoalDuration.permanent)
                        Text("Temporary").tag(GoalDuration.temporary)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 24)

                    if goalDuration == .temporary {
                        DatePicker("Start", selection: $startDate, in: today..., displayedComponents: .date)
                            .padding(.horizontal, 24)
                        DatePicker("End", selection: $endDate, in: startDate..., displayedComponents: .date)
                            .padding(.horizontal, 24)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 24)
                }

                Button(action: onConfirm) {
                    Group {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("Save Goal").fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(!isLimitSet ? Color.secondary : Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!isLimitSet || isLoading)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            .padding(.top, 24)
        }
    }
}

// MARK: - Color hex extension

extension Color {
    init?(hex: String) {
        var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
