import SwiftUI

/// A reusable phone-number input that lets the user pick a dialing country and type
/// only the national number, while exposing a clean E.164 string to its parent.
///
/// The bound `e164` is `""` when the field is empty (opted out), otherwise
/// `"+<dialCode><nationalDigits>"`. This component is presentation-only: validation
/// is the parent's responsibility (via `String.e164ValidationError`).
///
/// Re-formatting writes the field text back to itself, which re-fires `onChange`.
/// `suppressChange` skips that echo so it isn't mistaken for a user edit (which
/// otherwise made backspace delete two digits and changing country drop a digit).
struct CountryPhoneField: View {
    @Binding var e164: String
    /// External focus for the national-number field, so a parent "Done" toolbar
    /// button can dismiss the keyboard (a `.focused` on this container would be a no-op).
    var focused: FocusState<Bool>.Binding

    @State private var selectedCountry: Country = .default
    @State private var nationalText: String = ""
    @State private var showingPicker = false
    @State private var didInitialize = false
    @State private var suppressChange = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showingPicker = true
            } label: {
                HStack(spacing: 4) {
                    Text(selectedCountry.flag)
                    Text("+\(selectedCountry.dialCode)")
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            TextField("Phone number", text: $nationalText)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .focused(focused)
                .onChange(of: nationalText) { oldValue, newValue in
                    handleNationalChange(old: oldValue, new: newValue)
                }
        }
        .onAppear(perform: initializeIfNeeded)
        .onChange(of: e164) { _, newValue in
            // Keep internal state in sync if the parent replaces the value
            // (e.g. after a reload) while the field isn't being edited.
            syncFromBinding(newValue)
        }
        .sheet(isPresented: $showingPicker) {
            CountryPickerSheet(selectedCountry: selectedCountry) { country in
                selectCountry(country)
            }
        }
    }

    // MARK: - Logic

    private func handleNationalChange(old: String, new: String) {
        // Ignore the echo from our own reformatting write-back.
        if suppressChange {
            suppressChange = false
            return
        }
        // Deleting only a formatting char (e.g. ")") drops a digit rather than getting stuck.
        let digits = adjustedDigits(old: old, new: new)
        e164 = composeE164(dialCode: selectedCountry.dialCode, national: digits)
        setNationalText(displayText(for: digits, country: selectedCountry))
    }

    /// Set the field text programmatically, arming the echo guard so the resulting
    /// `onChange` isn't treated as a user edit. Only arms when the value changes,
    /// so the flag can't get stuck.
    private func setNationalText(_ value: String) {
        guard value != nationalText else { return }
        suppressChange = true
        nationalText = value
    }

    private func initializeIfNeeded() {
        guard !didInitialize else { return }
        didInitialize = true
        let parsed = parseE164(e164)
        selectedCountry = parsed.country
        setNationalText(displayText(for: parsed.national, country: parsed.country))
    }

    /// Re-derive internal state from a binding change originating outside the field,
    /// ignoring echoes of the value this field just produced itself.
    private func syncFromBinding(_ newValue: String) {
        let currentDigits = nationalText.filter(\.isNumber)
        if newValue == composeE164(dialCode: selectedCountry.dialCode, national: currentDigits) {
            return
        }
        let parsed = parseE164(newValue)
        selectedCountry = parsed.country
        setNationalText(displayText(for: parsed.national, country: parsed.country))
    }

    private func selectCountry(_ country: Country) {
        let digits = nationalText.filter(\.isNumber)
        selectedCountry = country
        setNationalText(displayText(for: digits, country: country))
        e164 = composeE164(dialCode: country.dialCode, national: digits)
        showingPicker = false
    }

    /// US numbers are formatted `(XXX) XXX-XXXX`; other countries show raw digits.
    private func displayText(for digits: String, country: Country) -> String {
        country.isoCode == "US" ? formatNationalUS(digits) : digits.filter(\.isNumber)
    }
}

// MARK: - Country picker sheet

private struct CountryPickerSheet: View {
    let selectedCountry: Country
    let onSelect: (Country) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filtered: [Country] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Country.all }
        // Strip a leading "+" so "+44" matches the "44" dial code.
        let digitsQuery = query.filter(\.isNumber)
        return Country.all.filter { country in
            if country.name.localizedCaseInsensitiveContains(query) { return true }
            if !digitsQuery.isEmpty, country.dialCode.hasPrefix(digitsQuery) { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { country in
                Button {
                    onSelect(country)
                } label: {
                    HStack(spacing: 12) {
                        Text(country.flag)
                        Text(country.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("+\(country.dialCode)")
                            .foregroundStyle(.secondary)
                        if country.isoCode == selectedCountry.isoCode {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Country or dial code")
            .navigationTitle("Select Country")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    struct Wrapper: View {
        @State private var phone = "+18015551234"
        @FocusState private var focused: Bool
        var body: some View {
            Form {
                CountryPhoneField(e164: $phone, focused: $focused)
                Text(phone.isEmpty ? "(empty)" : phone)
            }
        }
    }
    return Wrapper()
}
