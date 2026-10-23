import XCTest
@testable import Whale

final class PersonalDictionaryTests: XCTestCase {
    private func respell(_ text: String, _ vocabulary: [String]) -> String {
        PersonalDictionary(vocabulary: vocabulary, replacements: []).apply(to: text)
    }

    private func replace(_ text: String, _ pairs: [(String, String)]) -> String {
        PersonalDictionary(
            vocabulary: [],
            replacements: pairs.map { TextReplacement(spoken: $0.0, written: $0.1) }
        ).apply(to: text)
    }

    func testVocabularyFixesCase() {
        XCTAssertEqual(respell("deploy it to kubernetes today.", ["Kubernetes"]), "deploy it to Kubernetes today.")
    }

    func testVocabularyJoinsSplitWords() {
        XCTAssertEqual(respell("Open x code and post gres.", ["Xcode", "Postgres"]), "Open Xcode and Postgres.")
    }

    func testVocabularyFixesNearMisses() {
        XCTAssertEqual(respell("Run it on olama, then kubernetties.", ["Ollama", "Kubernetes"]), "Run it on Ollama, then Kubernetes.")
    }

    func testVocabularyLeavesOrdinaryWordsAlone() {
        // Different first letter, too far, or a term too short to guess at.
        XCTAssertEqual(respell("Sigma is linger in the cloud.", ["Figma", "Linear", "Claude", "Astro"]), "Sigma is linger in the cloud.")
    }

    func testVocabularyDoesNotJoinAcrossPunctuation() {
        XCTAssertEqual(respell("Press x. Code is next.", ["Xcode"]), "Press x. Code is next.")
    }

    func testVocabularyKeepsPossessive() {
        XCTAssertEqual(respell("figma's new file", ["Figma"]), "Figma's new file")
    }

    func testMultiWordTerm() {
        XCTAssertEqual(respell("ask claude code to fix it", ["Claude Code"]), "ask Claude Code to fix it")
    }

    func testReplacementIsCaseInsensitiveAndWholeWord() {
        XCTAssertEqual(replace("Be right back, I'm going to eat.", [("be right back", "brb")]), "brb, I'm going to eat.")
        XCTAssertEqual(replace("Maybe right backs", [("be right back", "brb")]), "Maybe right backs")
    }

    func testReplacementToleratesCommasBetweenWords() {
        XCTAssertEqual(replace("Send it to my, email please", [("my email", "hi@studio.co")]), "Send it to hi@studio.co please")
    }

    func testReplacementOutputIsTakenLiterally() {
        XCTAssertEqual(replace("Well shrug.", [("shrug", #"¯\_(ツ)_/¯ $1"#)]), #"Well ¯\_(ツ)_/¯ $1."#)
    }

    func testLongerReplacementWins() {
        XCTAssertEqual(
            replace("be right back", [("be right", "x"), ("be right back", "brb")]),
            "brb"
        )
    }

    func testVocabularyDoesNotRespellReplacementOutput() {
        let dictionary = PersonalDictionary(
            vocabulary: ["Studio"],
            replacements: [TextReplacement(spoken: "my email", written: "hi@studio.co")]
        )
        XCTAssertEqual(dictionary.apply(to: "my email"), "hi@studio.co")
    }

    func testStatsComputeSpeedAndSavings() {
        let stats = DictationStats(dictationCount: 2, words: 300, speakingSeconds: 120)
        XCTAssertEqual(stats.wordsPerMinute, 150)
        // 300 words typed at 40 wpm is 7.5 minutes; speaking took 2.
        XCTAssertEqual(stats.secondsSaved, 330, accuracy: 0.001)
    }
}
