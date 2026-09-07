import Testing
import Foundation
@testable import Nudge

// MARK: - Country

@Suite("Country")
@MainActor
struct CountryTests {

    @Test func flagDerivedFromIsoCode() {
        #expect(Country(isoCode: "US", dialCode: "1").flag == "🇺🇸")
        #expect(Country(isoCode: "GB", dialCode: "44").flag == "🇬🇧")
        #expect(Country(isoCode: "JP", dialCode: "81").flag == "🇯🇵")
    }

    @Test func defaultIsUS() {
        #expect(Country.default.isoCode == "US")
        #expect(Country.default.dialCode == "1")
    }

    @Test func allSortedByLocalizedName() {
        let names = Country.all.map(\.name)
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test func commonDialCodesCorrect() {
        func dial(_ iso: String) -> String? { Country.all.first { $0.isoCode == iso }?.dialCode }
        #expect(dial("US") == "1")
        #expect(dial("CA") == "1")
        #expect(dial("GB") == "44")
        #expect(dial("AU") == "61")
        #expect(dial("IN") == "91")
        #expect(dial("DE") == "49")
        #expect(dial("FR") == "33")
        #expect(dial("MX") == "52")
        #expect(dial("BR") == "55")
        #expect(dial("JP") == "81")
        #expect(dial("CN") == "86")
    }

    @Test func dialCodeMatchUS() {
        #expect(Country.forDialCodeMatch(e164: "+18015551234")?.isoCode == "US")
    }

    @Test func dialCodeMatchLongestPrefix() {
        // GB is +44; must not match a shorter code like +4.
        #expect(Country.forDialCodeMatch(e164: "+441234567890")?.isoCode == "GB")
    }

    @Test func dialCodeSharedPrefersUS() {
        // +1 is shared by US and CA — US wins.
        #expect(Country.forDialCodeMatch(e164: "+15145551234")?.isoCode == "US")
    }

    @Test func dialCodeMatchNoPlusReturnsNil() {
        #expect(Country.forDialCodeMatch(e164: "18015551234") == nil)
    }
}

// MARK: - Phone composing / parsing

@Suite("PhoneComposing")
@MainActor
struct PhoneComposingTests {

    @Test func composesE164FromFormattedNational() {
        #expect(composeE164(dialCode: "1", national: "(801) 555-1234") == "+18015551234")
    }

    @Test func emptyNationalReturnsEmpty() {
        #expect(composeE164(dialCode: "1", national: "") == "")
        #expect(composeE164(dialCode: "1", national: "   ") == "")
        #expect(composeE164(dialCode: "44", national: "()- ") == "")
    }

    @Test func parseSplitsCountryAndNational() {
        let result = parseE164("+18015551234")
        #expect(result.country.isoCode == "US")
        #expect(result.national == "8015551234")
    }

    @Test func parseEmptyReturnsDefault() {
        let result = parseE164("")
        #expect(result.country.isoCode == "US")
        #expect(result.national == "")
    }

    @Test func parseNonUSCountry() {
        let result = parseE164("+441234567890")
        #expect(result.country.isoCode == "GB")
        #expect(result.national == "1234567890")
    }

    @Test func roundTrip() {
        let numbers = ["+18015551234", "+441234567890", "+919876543210", "+861234567890"]
        for number in numbers {
            let parsed = parseE164(number)
            #expect(composeE164(dialCode: parsed.country.dialCode, national: parsed.national) == number)
        }
    }
}

// MARK: - US formatting

@Suite("USFormatting")
@MainActor
struct USFormattingTests {

    @Test func fullNumber() {
        #expect(formatNationalUS("8015551234") == "(801) 555-1234")
    }

    @Test func partialAfterPrefix() {
        #expect(formatNationalUS("801555") == "(801) 555")
    }

    @Test func partialAreaOnly() {
        #expect(formatNationalUS("801") == "(801)")
    }

    @Test func partialWithLineStarted() {
        #expect(formatNationalUS("80155512") == "(801) 555-12")
    }

    @Test func stripsNonDigits() {
        #expect(formatNationalUS("(801) 555-1234") == "(801) 555-1234")
    }

    @Test func emptyReturnsEmpty() {
        #expect(formatNationalUS("") == "")
    }

    @Test func ignoresExtraDigits() {
        #expect(formatNationalUS("80155512349999") == "(801) 555-1234")
    }
}

@Suite("BackspaceEditing")
struct BackspaceEditingTests {

    // Deleting the ")" from "(801)" leaves the same digits but a shorter string,
    // so a digit should be dropped (otherwise the ")" just gets re-added).
    @Test func backspaceOverClosingParenDropsDigit() {
        #expect(adjustedDigits(old: "(801)", new: "(801") == "80")
    }

    @Test func backspaceDownToSingleDigit() {
        #expect(adjustedDigits(old: "(8)", new: "(8") == "")
    }

    // Deleting an actual digit changes the digit count → keep the new digits.
    @Test func deletingADigitIsHonored() {
        #expect(adjustedDigits(old: "(801) 555", new: "(801) 55") == "80155")
    }

    // Typing a new digit lengthens the string → keep the new digits.
    @Test func typingADigitIsHonored() {
        #expect(adjustedDigits(old: "(801) 55", new: "(801) 555") == "801555")
    }

    // Non-formatted (non-US) input: deleting a digit is a normal digit deletion.
    @Test func rawDigitsDeletion() {
        #expect(adjustedDigits(old: "12345", new: "1234") == "1234")
    }
}
