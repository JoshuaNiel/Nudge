import Testing
@testable import Nudge

// MARK: - PasswordVisibility (docs/specs/auth-recovery.md, C4)

@Suite("PasswordVisibility")
@MainActor
struct PasswordVisibilityTests {

    @Test func defaultIsHidden() {
        let visibility = PasswordVisibility()
        #expect(visibility.isRevealed == false)
    }

    @Test func toggleRevealsThenHides() {
        var visibility = PasswordVisibility()
        visibility.toggle()
        #expect(visibility.isRevealed)
        visibility.toggle()
        #expect(visibility.isRevealed == false)
    }

    @Test func eachFieldTogglesIndependently() {
        var password = PasswordVisibility()
        let confirm = PasswordVisibility()
        password.toggle()
        #expect(password.isRevealed)
        #expect(confirm.isRevealed == false)
    }

    @Test func hiddenOffersShow() {
        let visibility = PasswordVisibility()
        #expect(visibility.toggleAccessibilityLabel == "Show password")
        #expect(visibility.toggleSystemImage == "eye")
    }

    @Test func revealedOffersHide() {
        var visibility = PasswordVisibility()
        visibility.toggle()
        #expect(visibility.toggleAccessibilityLabel == "Hide password")
        #expect(visibility.toggleSystemImage == "eye.slash")
    }

    @Test func activeVariantFollowsState() {
        var visibility = PasswordVisibility()
        #expect(visibility.activeVariant == .secure)
        visibility.toggle()
        #expect(visibility.activeVariant == .plain)
    }

    @Test func focusMovesToNewVariantWhenFieldWasFocused() {
        var visibility = PasswordVisibility()
        #expect(visibility.toggle(focused: .secure) == .plain)
        #expect(visibility.toggle(focused: .plain) == .secure)
    }

    @Test func focusStaysOffWhenFieldWasNotFocused() {
        var visibility = PasswordVisibility()
        #expect(visibility.toggle(focused: nil) == nil)
        #expect(visibility.isRevealed)
    }

    // MARK: Hidden input never writes (no publishing from inside a view update)

    @Test func onlyTheVisibleInputAcceptsEdits() {
        var visibility = PasswordVisibility()
        #expect(visibility.acceptsEdit(from: .secure))
        #expect(visibility.acceptsEdit(from: .plain) == false)
        visibility.toggle()
        #expect(visibility.acceptsEdit(from: .plain))
        #expect(visibility.acceptsEdit(from: .secure) == false)
    }

    // MARK: Focus on appear (replaces the two-way FocusState sync)

    @Test func focusOnAppearTargetsTheActiveInput() {
        var visibility = PasswordVisibility()
        #expect(visibility.initialFocus(focusOnAppear: true) == .secure)
        visibility.toggle()
        #expect(visibility.initialFocus(focusOnAppear: true) == .plain)
    }

    @Test func noFocusOnAppearByDefault() {
        let visibility = PasswordVisibility()
        #expect(visibility.initialFocus(focusOnAppear: false) == nil)
    }
}
