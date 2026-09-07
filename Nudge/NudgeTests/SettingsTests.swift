import Testing
import Foundation
@testable import Nudge

// MARK: - E.164 Validation

@Suite("E164 Validation")
struct E164ValidationTests {

    @Test func validNumbersPass() {
        #expect("+18015551234".isValidE164)
        #expect("+441234567".isValidE164)
    }

    @Test func missingPlusFails() {
        #expect("8015551234".isValidE164 == false)
    }

    @Test func leadingZeroFails() {
        #expect("+0123456".isValidE164 == false)
    }

    @Test func tooShortFails() {
        #expect("+1".isValidE164 == false)
    }

    @Test func tooLongFails() {
        #expect("+1234567890123456".isValidE164 == false)
    }

    @Test func emptyStringFails() {
        #expect("".isValidE164 == false)
    }

    // MARK: e164ValidationError — specific messages

    @Test func validationErrorNilForValidNumber() {
        #expect("+18015551234".e164ValidationError == nil)
    }

    @Test func validationErrorNilForEmpty() {
        #expect("".e164ValidationError == nil)
        #expect("   ".e164ValidationError == nil)
    }

    @Test func validationErrorMissingPlus() {
        #expect("8015551234".e164ValidationError != nil)
    }

    @Test func validationErrorNonDigitChars() {
        #expect("+1801abc1234".e164ValidationError != nil)
    }

    @Test func validationErrorLeadingZero() {
        #expect("+0123456789".e164ValidationError != nil)
    }

    @Test func validationErrorTooShort() {
        #expect("+1234567".e164ValidationError != nil)
    }

    @Test func validationErrorTooLong() {
        #expect("+1234567890123456".e164ValidationError != nil)
    }
}

// MARK: - Profile Model Coding

@Suite("Profile Model Coding")
struct ProfileModelCodingTests {

    @Test func roundTripUsesSnakeCaseKeys() throws {
        let profile = Profile(
            userId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            firstName: "Ada",
            lastName: "Lovelace",
            phoneNumber: "+18015551234",
            timeZone: "America/Denver",
            weekStart: 1
        )

        let data = try JSONEncoder().encode(profile)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("user_id"))
        #expect(json.contains("first_name"))
        #expect(json.contains("phone_number"))
        #expect(json.contains("time_zone"))
        #expect(json.contains("week_start"))

        #expect(json.contains("userId") == false)
        #expect(json.contains("firstName") == false)
        #expect(json.contains("phoneNumber") == false)
        #expect(json.contains("timeZone") == false)
        #expect(json.contains("weekStart") == false)

        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        #expect(decoded == profile)
    }

    @Test func decodesNullOptionalsAsNil() throws {
        let json = """
        {
            "user_id": "22222222-2222-2222-2222-222222222222",
            "first_name": null,
            "last_name": null,
            "phone_number": null,
            "time_zone": null,
            "week_start": 0
        }
        """
        let decoded = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        #expect(decoded.firstName == nil)
        #expect(decoded.lastName == nil)
        #expect(decoded.phoneNumber == nil)
        #expect(decoded.timeZone == nil)
        #expect(decoded.weekStart == 0)
    }
}

// MARK: - SettingsViewModel

@Suite("SettingsViewModel")
@MainActor
struct SettingsViewModelTests {

    private let userId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func makeProfile(
        firstName: String? = "Grace",
        lastName: String? = "Hopper",
        phoneNumber: String? = "+18015551234"
    ) -> Profile {
        Profile(
            userId: userId,
            firstName: firstName,
            lastName: lastName,
            phoneNumber: phoneNumber,
            timeZone: "America/Denver",
            weekStart: 0
        )
    }

    @Test func loadPopulatesFields() async {
        let mock = MockProfileService()
        mock.profileToReturn = makeProfile()
        let vm = SettingsViewModel(profileService: mock)

        await vm.load(userId: userId, email: "grace@example.com")

        #expect(vm.firstName == "Grace")
        #expect(vm.lastName == "Hopper")
        #expect(vm.phoneNumber == "+18015551234")
        #expect(vm.email == "grace@example.com")
    }

    @Test func loadMapsNilToEmptyString() async {
        let mock = MockProfileService()
        mock.profileToReturn = makeProfile(firstName: nil, lastName: nil, phoneNumber: nil)
        let vm = SettingsViewModel(profileService: mock)

        await vm.load(userId: userId, email: "x@example.com")

        #expect(vm.firstName == "")
        #expect(vm.lastName == "")
        #expect(vm.phoneNumber == "")
    }

    @Test func saveWithValidPhoneCallsServiceAndSetsDidSave() async {
        let mock = MockProfileService()
        let vm = SettingsViewModel(profileService: mock)
        vm.firstName = "Grace"
        vm.lastName = "Hopper"
        vm.phoneNumber = "  +18015551234  "

        await vm.save(userId: userId)

        #expect(mock.updateCallCount == 1)
        #expect(mock.savedPhoneNumber == "+18015551234")
        #expect(mock.savedFirstName == "Grace")
        #expect(mock.savedLastName == "Hopper")
        #expect(vm.didSave)
        #expect(vm.errorMessage == nil)
        #expect(vm.isSaving == false)
    }

    @Test func saveWithEmptyPhonePassesNil() async {
        let mock = MockProfileService()
        let vm = SettingsViewModel(profileService: mock)
        vm.firstName = "Grace"
        vm.lastName = "Hopper"
        vm.phoneNumber = "   "

        await vm.save(userId: userId)

        #expect(mock.updateCallCount == 1)
        #expect(mock.savedPhoneNumber == nil)
        #expect(vm.didSave)
    }

    @Test func saveWithInvalidPhoneSkipsServiceAndSetsError() async {
        let mock = MockProfileService()
        let vm = SettingsViewModel(profileService: mock)
        vm.firstName = "Grace"
        vm.lastName = "Hopper"
        vm.phoneNumber = "8015551234"

        #expect(vm.isPhoneValid == false)
        #expect(vm.phoneError != nil)

        await vm.save(userId: userId)

        #expect(mock.updateCallCount == 0)
        #expect(vm.errorMessage != nil)
        #expect(vm.didSave == false)
    }

    @Test func saveFailureSetsErrorAndResetsState() async {
        struct GenericError: Error {}
        let mock = MockProfileService()
        mock.errorToThrow = GenericError()
        let vm = SettingsViewModel(profileService: mock)
        vm.firstName = "Grace"
        vm.lastName = "Hopper"
        vm.phoneNumber = "+18015551234"

        await vm.save(userId: userId)

        #expect(vm.errorMessage != nil)
        #expect(vm.didSave == false)
        #expect(vm.isSaving == false)
    }

    // MARK: - Dirty-state & required fields

    @Test func noChangesAfterLoad() async {
        let mock = MockProfileService()
        mock.profileToReturn = makeProfile()
        let vm = SettingsViewModel(profileService: mock)

        await vm.load(userId: userId, email: "grace@example.com")

        #expect(vm.hasChanges == false)
        #expect(vm.canSave == false)
    }

    @Test func editingFieldFlipsHasChanges() async {
        let mock = MockProfileService()
        mock.profileToReturn = makeProfile()
        let vm = SettingsViewModel(profileService: mock)

        await vm.load(userId: userId, email: "grace@example.com")
        vm.firstName = "Ada"

        #expect(vm.hasChanges)
        #expect(vm.canSave)
    }

    @Test func emptyFirstNameBlocksSave() async {
        let mock = MockProfileService()
        mock.profileToReturn = makeProfile()
        let vm = SettingsViewModel(profileService: mock)

        await vm.load(userId: userId, email: "grace@example.com")
        vm.firstName = "   "

        #expect(vm.firstNameError != nil)
        #expect(vm.canSave == false)

        await vm.save(userId: userId)
        #expect(mock.updateCallCount == 0)
    }

    @Test func emptyLastNameBlocksSave() async {
        let mock = MockProfileService()
        mock.profileToReturn = makeProfile()
        let vm = SettingsViewModel(profileService: mock)

        await vm.load(userId: userId, email: "grace@example.com")
        vm.lastName = ""

        #expect(vm.lastNameError != nil)
        #expect(vm.canSave == false)
    }

    @Test func invalidPhoneBlocksSave() async {
        let mock = MockProfileService()
        mock.profileToReturn = makeProfile()
        let vm = SettingsViewModel(profileService: mock)

        await vm.load(userId: userId, email: "grace@example.com")
        vm.phoneNumber = "8015551234"

        #expect(vm.phoneError != nil)
        #expect(vm.canSave == false)
    }

    @Test func successfulSaveClearsChangesAndSetsDidSave() async {
        let mock = MockProfileService()
        mock.profileToReturn = makeProfile()
        let vm = SettingsViewModel(profileService: mock)

        await vm.load(userId: userId, email: "grace@example.com")
        vm.firstName = "Ada"
        #expect(vm.hasChanges)

        await vm.save(userId: userId)

        #expect(vm.didSave)
        #expect(vm.errorMessage == nil)
        #expect(vm.hasChanges == false)
    }
}

// MARK: - Mock

private final class MockProfileService: ProfileServiceProtocol {
    var profileToReturn: Profile?
    var errorToThrow: Error?

    var updateCallCount = 0
    var savedFirstName: String?
    var savedLastName: String?
    var savedPhoneNumber: String?

    func fetchProfile(userId: UUID) async throws -> Profile {
        if let errorToThrow { throw errorToThrow }
        return profileToReturn ?? Profile(
            userId: userId,
            firstName: nil,
            lastName: nil,
            phoneNumber: nil,
            timeZone: nil,
            weekStart: 0
        )
    }

    func updateProfile(userId: UUID, firstName: String, lastName: String, phoneNumber: String?) async throws {
        updateCallCount += 1
        savedFirstName = firstName
        savedLastName = lastName
        savedPhoneNumber = phoneNumber
        if let errorToThrow { throw errorToThrow }
    }
}
