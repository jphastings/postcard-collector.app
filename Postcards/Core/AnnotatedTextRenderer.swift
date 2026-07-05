import Foundation

/// Converts an `AnnotatedText` (whose `Annotation.start`/`end` are **UTF-8 byte offsets**,
/// per `types.Annotation` in the Go core — not `Character` or Unicode scalar counts) into
/// an `AttributedString`, mapping `em`→italic, `strong`→bold, `underline`→underline, and
/// `locale`→the run's language identifier.
enum AnnotatedTextRenderer {
    static func attributedString(for text: AnnotatedText) -> AttributedString {
        var result = AttributedString(text.text)
        guard !text.annotations.isEmpty else { return result }

        for annotation in text.annotations {
            guard let range = characterRange(in: text.text, utf8Start: annotation.start, utf8End: annotation.end),
                  let attributedRange = Range<AttributedString.Index>(range, in: result)
            else { continue }

            apply(annotation, to: &result, range: attributedRange)
        }

        return result
    }

    /// Converts a `[start, end)` UTF-8 byte offset pair into a `Range<String.Index>`.
    /// `String.UTF8View.Index` and `String.Index` are the same type, so once the offsets
    /// are walked to their position in the UTF-8 view, they're immediately valid indices
    /// into `text` itself — as long as they land on scalar boundaries, which annotation
    /// offsets recorded around whole characters always do.
    private static func characterRange(in text: String, utf8Start: Int, utf8End: Int) -> Range<String.Index>? {
        let utf8 = text.utf8
        guard
            utf8Start >= 0, utf8End >= utf8Start,
            let start = utf8.index(utf8.startIndex, offsetBy: utf8Start, limitedBy: utf8.endIndex),
            let end = utf8.index(utf8.startIndex, offsetBy: utf8End, limitedBy: utf8.endIndex)
        else {
            return nil
        }
        return start..<end
    }

    private static func apply(_ annotation: Annotation, to string: inout AttributedString, range: Range<AttributedString.Index>) {
        switch annotation.type {
        case .emphasis:
            string[range].inlinePresentationIntent = .emphasized
        case .strong:
            string[range].inlinePresentationIntent = .stronglyEmphasized
        case .underline:
            string[range].underlineStyle = .single
        case .locale:
            if let value = annotation.value {
                string[range].languageIdentifier = value
            }
        }
    }
}
