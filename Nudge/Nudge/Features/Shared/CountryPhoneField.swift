import SwiftUI

/// A reusable phone-number input that lets the user pick a dialing country and type
/// only the national number, while exposing a clean E.164 string to its parent.
///
/// The bound `e164` is `""` when the field is empty (opted out), otherwise
/// `"+<dialCode><nationalDigits>"`. This component is presentation-only: validation
/// is the parent's responsibility (via `String.e164ValidationError`).
struct CountryPhoneField: View {
    @Binding var e164: String
    /// External focus for the national-number field, so a parent "Done" toolbar
    /// button can dismiss the keyboard (a `.focused` on this container would be a no-op).
    var focused: FocusState<Bool>.Binding

    @State private var selectedCountry: Country = .default
    @State private var nationalText: String = ""
    @State private var showingPicker = false
    @State private var didInitialize = false

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
                .onChange(of: nationalText) { _, newValue in
                    handleNationalChange(newValue)
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

    private func initializeIfNeeded() {
        guard !didInitialize else { return }
        didInitialize = true
        let parsed = parseE164(e164)
        selectedCountry = parsed.country
        nationalText = displayText(for: parsed.national, country: parsed.country)
    }

    /// Re-derive internal state from a binding change originating outside the field.
    private func syncFromBinding(_ newValue: String) {
        // Ignore echoes of the value we just produced ourselves.
        if newValue == composeE164(dialCode: selectedCountry.dialCode, national: nationalText) {
            return
        }
        let parsed = parseE164(newValue)
        selectedCountry = parsed.country
        nationalText = displayText(for: parsed.national, country: parsed.country)
    }

    private func handleNationalChange(_ newValue: String) {
        let digits = newValue.filter(\.isNumber)
        let formatted = displayText(for: digits, country: selectedCountry)
        // Reflect formatting back into the field (US only re-formats).
        if formatted != newValue {
            nationalText = formatted
        }
        e164 = composeE164(dialCode: selectedCountry.dialCode, national: digits)
    }

    private func selectCountry(_ country: Country) {
        let digits = nationalText.filter(\.isNumber)
        selectedCountry = country
        nationalText = displayText(for: digits, country: country)
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
