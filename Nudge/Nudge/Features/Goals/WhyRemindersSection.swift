import SwiftUI

/// Goal detail → "Why" (Phase 4): the goal's whys with their percent, an Add row, swipe
/// to delete. State and writes belong to `WhyRemindersViewModel`, which the detail screen
/// owns; this view only renders it and reports taps.
struct WhyRemindersSection: View {
    // Callbacks
    @ObservedObject var viewModel: WhyRemindersViewModel
    var onAdd: () -> Void
    var onEdit: (WhyReminder) -> Void
    var onDelete: (WhyReminder) -> Void
    var onRetry: () -> Void

    var body: some View {
        Section {
            content
        } header: {
            Text("Why")
        } footer: {
            Text("When you reach a why's percentage of today's limit, Nudge shows it in a notification. Several whys at the same percentage take turns.")
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var content: some View {
        if let loadError = viewModel.loadError, !viewModel.hasLoaded {
            VStack(alignment: .leading, spacing: 8) {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("Try Again", action: onRetry)
                    .buttonStyle(.bordered)
            }
        } else if !viewModel.hasLoaded {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        } else {
            if viewModel.reminders.isEmpty {
                Text("Why did you set this limit? Write it down, and choose when Nudge should remind you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.reminders) { reminder in
                Button { onEdit(reminder) } label: { WhyReminderRow(reminder: reminder) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { onDelete(reminder) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            if let actionError = viewModel.actionError {
                Text(actionError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button(action: onAdd) {
                Label("Add a Why", systemImage: "plus.circle.fill")
            }
        }
    }
}

// MARK: - Row

private struct WhyReminderRow: View {
    let reminder: WhyReminder

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(reminder.message)
                .foregroundStyle(.primary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
            Text(WhyReminderRules.percentCaption(reminder.notifyPercent))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-tap to edit")
    }
}
