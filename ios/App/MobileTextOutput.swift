import Foundation

struct MobileTextOutput {
    struct Result: Equatable {
        let text: String
        var translationFailed = false
    }

    var session: URLSession = SharedSession.cloud

    func prepare(_ transcript: MobileRecognition.Result, target: String?, correct: Bool,
                 primary: CleanupConfiguration?, fallback: CleanupConfiguration?) async -> Result {
        let source = transcript.language ?? TextLanguage.detect(transcript.text)
        if let target, source != target {
            let translated = await Translator(session: session).translate(
                transcript.text, to: target, configuration: primary, fallback: fallback,
                sourceLanguage: source, correctRecognition: correct
            )
            return Result(text: translated.text, translationFailed: !translated.translated)
        }
        guard correct else { return Result(text: transcript.text) }
        let cleaned = await CleanupPipeline(session: session).clean(transcript.text, configuration: primary, fallback: fallback)
        return Result(text: cleaned.text)
    }
}
