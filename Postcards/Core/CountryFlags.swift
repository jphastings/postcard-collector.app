import Foundation

/// Converts the ISO 3166-1 alpha-3 country codes stored in postcard metadata
/// (`Location.countryCode`, e.g. `"ITA"`) into flag emoji, for display in `CardInfoPanel`.
///
/// Foundation's `Locale`/`Region` APIs only expose alpha-2 codes, so this keeps its own
/// static alpha-3 → alpha-2 table (ISO 3166-1, ~250 currently-assigned entries) rather
/// than pulling in a third-party dependency for one lookup.
enum CountryFlags {
    /// Returns a flag emoji for an ISO 3166-1 alpha-3 code, or `nil` if the code is
    /// unrecognized.
    static func flag(forAlpha3 code: String) -> String? {
        guard let alpha2 = alpha3ToAlpha2[code.uppercased()] else { return nil }
        return flag(forAlpha2: alpha2)
    }

    /// Converts an ISO 3166-1 alpha-2 code (e.g. what `MKLocalSearch`/`CLPlacemark` return)
    /// into the alpha-3 form stored in postcard metadata (`Location.countryCode`), or `nil`
    /// if unrecognized. Built once, lazily, by inverting `alpha3ToAlpha2` — still the only
    /// place country-code data lives.
    static func alpha3(forAlpha2 code: String) -> String? {
        alpha2ToAlpha3[code.uppercased()]
    }

    private static let alpha2ToAlpha3: [String: String] = {
        var inverted: [String: String] = [:]
        for (alpha3, alpha2) in alpha3ToAlpha2 {
            inverted[alpha2] = alpha3
        }
        return inverted
    }()

    /// Builds a flag emoji from an ISO 3166-1 alpha-2 code by combining two Regional
    /// Indicator Symbols (e.g. "IT" -> 🇮🇹), which is how flag emoji are composed.
    static func flag(forAlpha2 code: String) -> String? {
        let upper = code.uppercased()
        guard upper.count == 2, upper.unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.isAlphabetic }) else {
            return nil
        }

        var scalars = String.UnicodeScalarView()
        for scalar in upper.unicodeScalars {
            // Regional Indicator Symbols start at U+1F1E6 ('A'); offset from ASCII 'A' (0x41).
            guard let indicator = Unicode.Scalar(0x1F1E6 + (scalar.value - 0x41)) else { return nil }
            scalars.append(indicator)
        }
        return String(scalars)
    }

    static let alpha3ToAlpha2: [String: String] = [
        "AFG": "AF", "ALA": "AX", "ALB": "AL", "DZA": "DZ", "ASM": "AS", "AND": "AD",
        "AGO": "AO", "AIA": "AI", "ATA": "AQ", "ATG": "AG", "ARG": "AR", "ARM": "AM",
        "ABW": "AW", "AUS": "AU", "AUT": "AT", "AZE": "AZ", "BHS": "BS", "BHR": "BH",
        "BGD": "BD", "BRB": "BB", "BLR": "BY", "BEL": "BE", "BLZ": "BZ", "BEN": "BJ",
        "BMU": "BM", "BTN": "BT", "BOL": "BO", "BES": "BQ", "BIH": "BA", "BWA": "BW",
        "BVT": "BV", "BRA": "BR", "IOT": "IO", "BRN": "BN", "BGR": "BG", "BFA": "BF",
        "BDI": "BI", "CPV": "CV", "KHM": "KH", "CMR": "CM", "CAN": "CA", "CYM": "KY",
        "CAF": "CF", "TCD": "TD", "CHL": "CL", "CHN": "CN", "CXR": "CX", "CCK": "CC",
        "COL": "CO", "COM": "KM", "COG": "CG", "COD": "CD", "COK": "CK", "CRI": "CR",
        "CIV": "CI", "HRV": "HR", "CUB": "CU", "CUW": "CW", "CYP": "CY", "CZE": "CZ",
        "DNK": "DK", "DJI": "DJ", "DMA": "DM", "DOM": "DO", "ECU": "EC", "EGY": "EG",
        "SLV": "SV", "GNQ": "GQ", "ERI": "ER", "EST": "EE", "SWZ": "SZ", "ETH": "ET",
        "FLK": "FK", "FRO": "FO", "FJI": "FJ", "FIN": "FI", "FRA": "FR", "GUF": "GF",
        "PYF": "PF", "ATF": "TF", "GAB": "GA", "GMB": "GM", "GEO": "GE", "DEU": "DE",
        "GHA": "GH", "GIB": "GI", "GRC": "GR", "GRL": "GL", "GRD": "GD", "GLP": "GP",
        "GUM": "GU", "GTM": "GT", "GGY": "GG", "GIN": "GN", "GNB": "GW", "GUY": "GY",
        "HTI": "HT", "HMD": "HM", "VAT": "VA", "HND": "HN", "HKG": "HK", "HUN": "HU",
        "ISL": "IS", "IND": "IN", "IDN": "ID", "IRN": "IR", "IRQ": "IQ", "IRL": "IE",
        "IMN": "IM", "ISR": "IL", "ITA": "IT", "JAM": "JM", "JPN": "JP", "JEY": "JE",
        "JOR": "JO", "KAZ": "KZ", "KEN": "KE", "KIR": "KI", "PRK": "KP", "KOR": "KR",
        "KWT": "KW", "KGZ": "KG", "LAO": "LA", "LVA": "LV", "LBN": "LB", "LSO": "LS",
        "LBR": "LR", "LBY": "LY", "LIE": "LI", "LTU": "LT", "LUX": "LU", "MAC": "MO",
        "MDG": "MG", "MWI": "MW", "MYS": "MY", "MDV": "MV", "MLI": "ML", "MLT": "MT",
        "MHL": "MH", "MTQ": "MQ", "MRT": "MR", "MUS": "MU", "MYT": "YT", "MEX": "MX",
        "FSM": "FM", "MDA": "MD", "MCO": "MC", "MNG": "MN", "MNE": "ME", "MSR": "MS",
        "MAR": "MA", "MOZ": "MZ", "MMR": "MM", "NAM": "NA", "NRU": "NR", "NPL": "NP",
        "NLD": "NL", "NCL": "NC", "NZL": "NZ", "NIC": "NI", "NER": "NE", "NGA": "NG",
        "NIU": "NU", "NFK": "NF", "MKD": "MK", "MNP": "MP", "NOR": "NO", "OMN": "OM",
        "PAK": "PK", "PLW": "PW", "PSE": "PS", "PAN": "PA", "PNG": "PG", "PRY": "PY",
        "PER": "PE", "PHL": "PH", "PCN": "PN", "POL": "PL", "PRT": "PT", "PRI": "PR",
        "QAT": "QA", "REU": "RE", "ROU": "RO", "RUS": "RU", "RWA": "RW", "BLM": "BL",
        "SHN": "SH", "KNA": "KN", "LCA": "LC", "MAF": "MF", "SPM": "PM", "VCT": "VC",
        "WSM": "WS", "SMR": "SM", "STP": "ST", "SAU": "SA", "SEN": "SN", "SRB": "RS",
        "SYC": "SC", "SLE": "SL", "SGP": "SG", "SXM": "SX", "SVK": "SK", "SVN": "SI",
        "SLB": "SB", "SOM": "SO", "ZAF": "ZA", "SGS": "GS", "SSD": "SS", "ESP": "ES",
        "LKA": "LK", "SDN": "SD", "SUR": "SR", "SJM": "SJ", "SWE": "SE", "CHE": "CH",
        "SYR": "SY", "TWN": "TW", "TJK": "TJ", "TZA": "TZ", "THA": "TH", "TLS": "TL",
        "TGO": "TG", "TKL": "TK", "TON": "TO", "TTO": "TT", "TUN": "TN", "TUR": "TR",
        "TKM": "TM", "TCA": "TC", "TUV": "TV", "UGA": "UG", "UKR": "UA", "ARE": "AE",
        "GBR": "GB", "USA": "US", "UMI": "UM", "URY": "UY", "UZB": "UZ", "VUT": "VU",
        "VEN": "VE", "VNM": "VN", "VGB": "VG", "VIR": "VI", "WLF": "WF", "ESH": "EH",
        "YEM": "YE", "ZMB": "ZM", "ZWE": "ZW", "XKX": "XK",
    ]
}
