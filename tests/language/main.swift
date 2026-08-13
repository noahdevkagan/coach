import Foundation

var failed = false
func check(_ condition: Bool, _ label: String) {
    print("language \(label): \(condition ? "PASS" : "FAIL")")
    if !condition { failed = true }
}

let supportedCodes: Set<String> = [
    "en", "bg", "hr", "cs", "da", "nl", "et", "fi", "fr", "de", "el",
    "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl",
    "es", "sv", "uk",
]
let explicit = MeetingLanguageSelection.allCases.filter { $0 != .system }
check(explicit.count == 25, "exposes 25 explicit languages")
check(Set(explicit.map(\.rawValue)) == supportedCodes, "ISO mapping is exact")
check(explicit.allSatisfy { !$0.englishName.isEmpty && !$0.pickerName.isEmpty },
      "every language has picker copy")
// Engine routing is asserted on the Apple Silicon path explicitly, so the
// result doesn't depend on which machine runs the gate.
check(explicit.allSatisfy {
    $0.resolved(neuralModelsSupported: true).preferredEngine
        == ($0 == .english ? .parakeetV2 : .parakeetV3)
}, "all 25 languages route to the required engine")

let english = MeetingLanguageSelection.english.resolved(localeIdentifier: "es_ES")
check(english.code == "en" && english.preferredEngine == .parakeetV2,
      "explicit English routes to v2 regardless of Mac")

let spanishMac = MeetingLanguageSelection.system.resolved(
    localeIdentifier: "es_ES", neuralModelsSupported: true)
check(spanishMac.code == "es" && spanishMac.preferredEngine == .parakeetV3,
      "Mac Spanish resolves to v3")
check(spanishMac.selection == .system && !spanishMac.usedUnsupportedSystemFallback,
      "Mac-language provenance retained")

let unsupportedMac = MeetingLanguageSelection.system.resolved(localeIdentifier: "ja_JP")
check(unsupportedMac.code == "en" && unsupportedMac.usedUnsupportedSystemFallback,
      "unsupported Mac language explains English fallback")

// Intel can't run Parakeet at all, so every selection resolves to English
// rather than refusing to start the meeting. The wanted language is retained
// for the Settings explanation, and English is never marked as a fallback.
let intelSpanish = MeetingLanguageSelection.spanish.resolved(
    localeIdentifier: "en_US", neuralModelsSupported: false)
check(intelSpanish.code == "en" && intelSpanish.preferredEngine == .parakeetV2,
      "Intel forces an explicit non-English selection to English")
check(intelSpanish.intelFallbackFrom == .spanish && intelSpanish.usedIntelEnglishFallback,
      "Intel fallback names the language that was wanted")
check(!intelSpanish.usedUnsupportedSystemFallback,
      "Intel fallback is not confused with an unsupported Mac language")

let intelFrenchMac = MeetingLanguageSelection.system.resolved(
    localeIdentifier: "fr_FR", neuralModelsSupported: false)
check(intelFrenchMac.code == "en" && intelFrenchMac.intelFallbackFrom == .french,
      "Intel Mac-language French resolves to English, not a refused session")

let intelEnglish = MeetingLanguageSelection.system.resolved(
    localeIdentifier: "en_US", neuralModelsSupported: false)
check(intelEnglish.code == "en" && !intelEnglish.usedIntelEnglishFallback,
      "Intel English needs no fallback explanation")

let siliconFrench = MeetingLanguageSelection.system.resolved(
    localeIdentifier: "fr_FR", neuralModelsSupported: true)
check(siliconFrench.code == "fr" && !siliconFrench.usedIntelEnglishFallback,
      "Apple Silicon keeps the selected language")

let persisted = MeetingLanguageSelection.resolvedPersistedCode("uk")
check(persisted?.language == .ukrainian && persisted?.englishName == "Ukrainian",
      "saved ISO language restores review policy")
check(MeetingLanguageSelection.resolvedPersistedCode("ja") == nil,
      "unsupported saved ISO stays legacy/dominant-language mode")

UserDefaults.standard.set("fr", forKey: MeetingLanguageSelection.defaultsKey)
check(MeetingLanguageSelection.current == .french, "stored global selection loads")
UserDefaults.standard.removeObject(forKey: MeetingLanguageSelection.defaultsKey)
check(MeetingLanguageSelection.current == .system, "unset selection defaults to Mac language")

exit(failed ? 1 : 0)
