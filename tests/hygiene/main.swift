import Foundation

// TranscriptCleanup checks: the wake-word filter and the vocabulary
// normalizer are deterministic text transforms — table-test them straight.
// Cases come from the 2026-07-29 field report (two real test calls
// compared against another tool's export of the same meetings).

var fail = false
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("hygiene \(label): \(ok ? "PASS" : "FAIL\(detail.isEmpty ? "" : " — \(detail)")")")
    if !ok { fail = true }
}

// MARK: - Wake-word filter

// Pure activations — dropped.
for junk in ["Siri", "Siri.", "Hey Siri", "Hey Siri.", "hey siri",
             "Okay Google", "OK Google.", "Alexa", "Hey Siri, Siri"] {
    check(WakeWordFilter.isWakeNoise(junk), "drops \"\(junk)\"")
}

// Real speech that merely mentions an assistant — always kept.
for real in ["Siri, set a timer for ten minutes", "We integrated Siri support",
             "Google it after the call", "Google", "Hey", "Okay.",
             "Hey, so about the pricing", "Alexa integration is on the roadmap"] {
    check(!WakeWordFilter.isWakeNoise(real), "keeps \"\(real)\"")
}

// MARK: - Vocabulary normalizer (built-in defaults)

let vocab = VocabularyNormalizer()

// The field report's exact garbles.
check(vocab.normalize("There's no Tidy Khắc Việt branding on it")
      == "There's no TidyCal branding on it",
      "Vietnamese-script garble repaired to TidyCal")
check(vocab.normalize("no tidy cow branding") == "no TidyCal branding",
      "\"tidy cow\" → TidyCal")
check(vocab.normalize("Is that from their App Sumo account?")
      == "Is that from their AppSumo account?",
      "\"App Sumo\" → AppSumo")
check(vocab.normalize("the Epsom deal and the apsu listing")
      == "the AppSumo deal and the AppSumo listing",
      "\"Epsom\"/\"apsu\" → AppSumo")
check(vocab.normalize("we'll push it through send fox tomorrow")
      == "we'll push it through SendFox tomorrow",
      "\"send fox\" → SendFox")
check(vocab.normalize("about eight grand in MRI pay") == "about eight grand in MRR",
      "\"MRI pay\" → MRR")
check(vocab.normalize("mostly u g c content") == "mostly UGC content",
      "\"u g c\" → UGC")

// Casing self-heals; correct text is untouched.
check(vocab.normalize("appsumo and tidycal") == "AppSumo and TidyCal",
      "canonical casing enforced")
check(vocab.normalize("AppSumo bought TidyCal.") == "AppSumo bought TidyCal.",
      "already-correct text unchanged")

// Word boundaries: no substring bleeding.
check(vocab.normalize("the apps you mentioned") == "the apps you mentioned",
      "\"apps\" not mangled by AppSumo aliases")
check(vocab.normalize("a tidy calendar") == "a tidy calendar",
      "\"tidy calendar\" untouched (boundary after cal)")

// Correct proper nouns with Western diacritics survive — they were RIGHT.
check(vocab.normalize("Mbappé, Dembélé, and Tuchel") == "Mbappé, Dembélé, and Tuchel",
      "Western-diacritic names untouched")
check(vocab.normalize("a café tête-à-tête") == "a café tête-à-tête",
      "French diacritics untouched")

// Vietnamese-script artifacts fold to ASCII even outside known terms.
check(VocabularyNormalizer.foldVietnameseArtifacts("Khắc Việt đúng")
      == "Khac Viet dung",
      "Vietnamese marks fold to ASCII")

// "UTC" must never be rewritten by default — it's a real timezone.
check(vocab.normalize("let's sync at 3pm UTC") == "let's sync at 3pm UTC",
      "UTC untouched by default")

// MARK: - Custom vocabulary parsing

let custom = VocabularyNormalizer(customText: """
    # comment line
    Rockford = rock furred, rockferd
    UGC = utc
    Rollworks
    """)
check(custom.normalize("the rock furred pilot") == "the Rockford pilot",
      "custom alias applied")
check(custom.normalize("3pm utc works") == "3pm UGC works",
      "user-added utc alias merges into the UGC defaults")
check(custom.normalize("ROLLWORKS demo") == "Rollworks demo",
      "bare custom term normalizes casing")
check(custom.normalize("mostly u g c content") == "mostly UGC content",
      "defaults survive a custom list")

exit(fail ? 1 : 0)
