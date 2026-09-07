import Foundation

// MARK: - Country

/// A single dialing region. Only the `isoCode` → `dialCode` mapping is maintained
/// here; the flag emoji and localized name are derived at runtime.
struct Country: Identifiable, Hashable {
    /// ISO 3166-1 alpha-2 region code (e.g. "US", "GB"). Also serves as the identity.
    let isoCode: String
    /// The international dialing code, digits only, no leading "+" (e.g. "1", "44").
    let dialCode: String

    var id: String { isoCode }

    /// Flag emoji derived from the ISO code via regional-indicator scalars.
    var flag: String {
        let base: UInt32 = 0x1F1E6 // Regional Indicator Symbol Letter A
        var result = ""
        for scalar in isoCode.uppercased().unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { return isoCode }
            if let indicator = Unicode.Scalar(base + (scalar.value - 65)) {
                result.unicodeScalars.append(indicator)
            }
        }
        return result.isEmpty ? isoCode : result
    }

    /// Localized display name for the region, falling back to the raw ISO code.
    var name: String {
        Locale.current.localizedString(forRegionCode: isoCode) ?? isoCode
    }
}

// MARK: - Static data & lookup

extension Country {
    /// The default country used when nothing else can be inferred.
    static let `default` = Country(isoCode: "US", dialCode: "1")

    /// Comprehensive ISO 3166-1 alpha-2 → dial code table, sorted by localized name.
    static let all: [Country] = rawData
        .map { Country(isoCode: $0.0, dialCode: $0.1) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    /// Best-matching country for a full E.164 string by LONGEST dial-code prefix.
    ///
    /// When several countries share a dial code (e.g. "+1" → US, CA, …) the tie is
    /// broken in favor of the United States, then Canada, then remaining regions.
    static func forDialCodeMatch(e164: String) -> Country? {
        let trimmed = e164.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("+") else { return nil }
        let digits = String(trimmed.dropFirst()).filter(\.isNumber)
        guard !digits.isEmpty else { return nil }

        var best: Country?
        var bestLength = 0
        for country in all {
            let code = country.dialCode
            guard digits.hasPrefix(code) else { continue }
            if code.count > bestLength {
                best = country
                bestLength = code.count
            } else if code.count == bestLength, let current = best {
                // Same-length collision: prefer US, then CA, then anything else.
                if preferenceRank(country) < preferenceRank(current) {
                    best = country
                }
            }
        }
        return best
    }

    /// Lower rank wins collisions. Primary regions for a shared dial code are
    /// prioritized explicitly (US for +1, GB for +44).
    private static func preferenceRank(_ country: Country) -> Int {
        switch country.isoCode {
        case "US": return 0
        case "CA": return 1
        case "GB": return 0
        default:   return 2
        }
    }
}

// MARK: - Raw dial-code data

extension Country {
    /// (isoCode, dialCode) pairs. Digits only, no "+".
    fileprivate static let rawData: [(String, String)] = [
        ("AF", "93"), ("AL", "355"), ("DZ", "213"), ("AS", "1"), ("AD", "376"),
        ("AO", "244"), ("AI", "1"), ("AG", "1"), ("AR", "54"), ("AM", "374"),
        ("AW", "297"), ("AU", "61"), ("AT", "43"), ("AZ", "994"), ("BS", "1"),
        ("BH", "973"), ("BD", "880"), ("BB", "1"), ("BY", "375"), ("BE", "32"),
        ("BZ", "501"), ("BJ", "229"), ("BM", "1"), ("BT", "975"), ("BO", "591"),
        ("BA", "387"), ("BW", "267"), ("BR", "55"), ("IO", "246"), ("BN", "673"),
        ("BG", "359"), ("BF", "226"), ("BI", "257"), ("KH", "855"), ("CM", "237"),
        ("CA", "1"), ("CV", "238"), ("KY", "1"), ("CF", "236"), ("TD", "235"),
        ("CL", "56"), ("CN", "86"), ("CO", "57"), ("KM", "269"), ("CG", "242"),
        ("CD", "243"), ("CK", "682"), ("CR", "506"), ("CI", "225"), ("HR", "385"),
        ("CU", "53"), ("CW", "599"), ("CY", "357"), ("CZ", "420"), ("DK", "45"),
        ("DJ", "253"), ("DM", "1"), ("DO", "1"), ("EC", "593"), ("EG", "20"),
        ("SV", "503"), ("GQ", "240"), ("ER", "291"), ("EE", "372"), ("SZ", "268"),
        ("ET", "251"), ("FK", "500"), ("FO", "298"), ("FJ", "679"), ("FI", "358"),
        ("FR", "33"), ("GF", "594"), ("PF", "689"), ("GA", "241"), ("GM", "220"),
        ("GE", "995"), ("DE", "49"), ("GH", "233"), ("GI", "350"), ("GR", "30"),
        ("GL", "299"), ("GD", "1"), ("GP", "590"), ("GU", "1"), ("GT", "502"),
        ("GG", "44"), ("GN", "224"), ("GW", "245"), ("GY", "592"), ("HT", "509"),
        ("HN", "504"), ("HK", "852"), ("HU", "36"), ("IS", "354"), ("IN", "91"),
        ("ID", "62"), ("IR", "98"), ("IQ", "964"), ("IE", "353"), ("IM", "44"),
        ("IL", "972"), ("IT", "39"), ("JM", "1"), ("JP", "81"), ("JE", "44"),
        ("JO", "962"), ("KZ", "7"), ("KE", "254"), ("KI", "686"), ("KP", "850"),
        ("KR", "82"), ("KW", "965"), ("KG", "996"), ("LA", "856"), ("LV", "371"),
        ("LB", "961"), ("LS", "266"), ("LR", "231"), ("LY", "218"), ("LI", "423"),
        ("LT", "370"), ("LU", "352"), ("MO", "853"), ("MG", "261"), ("MW", "265"),
        ("MY", "60"), ("MV", "960"), ("ML", "223"), ("MT", "356"), ("MH", "692"),
        ("MQ", "596"), ("MR", "222"), ("MU", "230"), ("YT", "262"), ("MX", "52"),
        ("FM", "691"), ("MD", "373"), ("MC", "377"), ("MN", "976"), ("ME", "382"),
        ("MS", "1"), ("MA", "212"), ("MZ", "258"), ("MM", "95"), ("NA", "264"),
        ("NR", "674"), ("NP", "977"), ("NL", "31"), ("NC", "687"), ("NZ", "64"),
        ("NI", "505"), ("NE", "227"), ("NG", "234"), ("NU", "683"), ("NF", "672"),
        ("MK", "389"), ("MP", "1"), ("NO", "47"), ("OM", "968"), ("PK", "92"),
        ("PW", "680"), ("PS", "970"), ("PA", "507"), ("PG", "675"), ("PY", "595"),
        ("PE", "51"), ("PH", "63"), ("PL", "48"), ("PT", "351"), ("PR", "1"),
        ("QA", "974"), ("RE", "262"), ("RO", "40"), ("RU", "7"), ("RW", "250"),
        ("BL", "590"), ("SH", "290"), ("KN", "1"), ("LC", "1"), ("MF", "590"),
        ("PM", "508"), ("VC", "1"), ("WS", "685"), ("SM", "378"), ("ST", "239"),
        ("SA", "966"), ("SN", "221"), ("RS", "381"), ("SC", "248"), ("SL", "232"),
        ("SG", "65"), ("SX", "1"), ("SK", "421"), ("SI", "386"), ("SB", "677"),
        ("SO", "252"), ("ZA", "27"), ("SS", "211"), ("ES", "34"), ("LK", "94"),
        ("SD", "249"), ("SR", "597"), ("SE", "46"), ("CH", "41"), ("SY", "963"),
        ("TW", "886"), ("TJ", "992"), ("TZ", "255"), ("TH", "66"), ("TL", "670"),
        ("TG", "228"), ("TK", "690"), ("TO", "676"), ("TT", "1"), ("TN", "216"),
        ("TR", "90"), ("TM", "993"), ("TC", "1"), ("TV", "688"), ("UG", "256"),
        ("UA", "380"), ("AE", "971"), ("GB", "44"), ("US", "1"), ("UY", "598"),
        ("UZ", "998"), ("VU", "678"), ("VA", "379"), ("VE", "58"), ("VN", "84"),
        ("VG", "1"), ("VI", "1"), ("WF", "681"), ("YE", "967"), ("ZM", "260"),
        ("ZW", "263")
    ]
}

// MARK: - Pure phone composing / parsing

/// Compose an E.164 string from a dial code and a (possibly formatted) national number.
///
/// - Non-digit characters in `national` are stripped.
/// - An empty national number returns `""` (interpreted as "opted out").
func composeE164(dialCode: String, national: String) -> String {
    let digits = national.filter(\.isNumber)
    guard !digits.isEmpty else { return "" }
    return "+" + dialCode + digits
}

/// Split a full E.164 string into its country and national-number parts.
///
/// - An empty string returns `(.default, "")`.
/// - If no country matches, defaults to US and treats the digits after "+" as national.
func parseE164(_ e164: String) -> (country: Country, national: String) {
    let trimmed = e164.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return (.default, "") }

    guard let country = Country.forDialCodeMatch(e164: trimmed) else {
        // Fall back to US, keeping whatever digits followed the "+".
        let digits = trimmed.hasPrefix("+")
            ? String(trimmed.dropFirst()).filter(\.isNumber)
            : trimmed.filter(\.isNumber)
        return (.default, digits)
    }

    let allDigits = String(trimmed.dropFirst()).filter(\.isNumber)
    let national = String(allDigits.dropFirst(country.dialCode.count))
    return (country, national)
}

/// Progressively format up to 10 US digits as `(XXX) XXX-XXXX`.
/// For fewer than 10 digits, formats as far as the input allows.
/// Extra digits beyond 10 are ignored.
func formatNationalUS(_ digits: String) -> String {
    let d = Array(digits.filter(\.isNumber).prefix(10))
    guard !d.isEmpty else { return "" }

    let area = String(d.prefix(3))
    if d.count <= 3 {
        return "(\(area))"
    }

    let prefix = String(d[3..<min(6, d.count)])
    if d.count <= 6 {
        return "(\(area)) \(prefix)"
    }

    let line = String(d[6..<d.count])
    return "(\(area)) \(prefix)-\(line)"
}
