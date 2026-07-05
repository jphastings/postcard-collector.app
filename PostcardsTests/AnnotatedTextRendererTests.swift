import XCTest

final class AnnotatedTextRendererTests: XCTestCase {
    func testPlainTextRoundTripsWithNoAnnotations() {
        let attributed = AnnotatedTextRenderer.attributedString(for: AnnotatedText(text: "Hello"))
        XCTAssertEqual(String(attributed.characters), "Hello")
    }

    func testEmphasisAndStrongMapToInlinePresentationIntent() {
        // Byte offsets here are plain ASCII, so they line up with Character offsets too —
        // the multi-byte cases below are what actually exercise the UTF-8 math.
        let text = AnnotatedText(text: "Wish you were here", annotations: [
            Annotation(type: .emphasis, value: nil, start: 5, end: 8), // "you"
            Annotation(type: .strong, value: nil, start: 14, end: 18), // "here"
        ])
        let attributed = AnnotatedTextRenderer.attributedString(for: text)

        XCTAssertEqual(substring(attributed, where: { $0.inlinePresentationIntent == .emphasized }), "you")
        XCTAssertEqual(substring(attributed, where: { $0.inlinePresentationIntent == .stronglyEmphasized }), "here")
    }

    func testUnderlineAnnotation() {
        let text = AnnotatedText(text: "important", annotations: [
            Annotation(type: .underline, value: nil, start: 0, end: 9),
        ])
        let attributed = AnnotatedTextRenderer.attributedString(for: text)
        XCTAssertEqual(substring(attributed, where: { $0.underlineStyle != nil }), "important")
    }

    func testLocaleAnnotationSetsLanguageIdentifier() {
        let text = AnnotatedText(text: "Bonjour", annotations: [
            Annotation(type: .locale, value: "fr-FR", start: 0, end: 7),
        ])
        let attributed = AnnotatedTextRenderer.attributedString(for: text)
        XCTAssertEqual(attributed.runs.first?.languageIdentifier, "fr-FR")
    }

    /// From the left-hand fixture card's back transcription: "ü" and "ß" are each 2 UTF-8
    /// bytes, so "Berlin" (the `em` annotation) starts at *byte* 12, not character 12.
    func testMultiByteGermanOffsetsLandOnTheRightCharacters() {
        let text = AnnotatedText(text: "Grüße aus Berlin!", annotations: [
            Annotation(type: .emphasis, value: nil, start: 12, end: 18),
        ])
        let attributed = AnnotatedTextRenderer.attributedString(for: text)
        XCTAssertEqual(substring(attributed, where: { $0.inlinePresentationIntent == .emphasized }), "Berlin")
    }

    /// From the right-hand fixture card's back transcription: each kanji is 3 UTF-8 bytes,
    /// so "京都" (Kyoto, the `underline` annotation) spans bytes 0..<6, not characters 0..<6.
    func testMultiByteJapaneseOffsetsLandOnTheRightCharacters() {
        let text = AnnotatedText(text: "京都からこんにちは!", annotations: [
            Annotation(type: .underline, value: nil, start: 0, end: 6),
        ])
        let attributed = AnnotatedTextRenderer.attributedString(for: text)
        XCTAssertEqual(substring(attributed, where: { $0.underlineStyle != nil }), "京都")
    }

    func testOutOfRangeAnnotationIsIgnoredRatherThanCrashing() {
        let text = AnnotatedText(text: "Hi", annotations: [
            Annotation(type: .strong, value: nil, start: 0, end: 999),
        ])
        let attributed = AnnotatedTextRenderer.attributedString(for: text)
        XCTAssertEqual(String(attributed.characters), "Hi")
    }

    private func substring(_ attributed: AttributedString, where predicate: (AttributedString.Runs.Run) -> Bool) -> String {
        attributed.runs
            .filter(predicate)
            .map { String(attributed[$0.range].characters) }
            .joined()
    }
}
