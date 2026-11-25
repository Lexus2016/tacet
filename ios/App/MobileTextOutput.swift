import Foundation

struct MobileTextOutput {
    struct Result: Equatable {
        let text: String
        var translationFailed = false
    }

    var session: URLSession = SharedSession.cloud

    func editSelection(_ selection: String, instruction: String,
                       primary: CleanupConfiguration?, fallback: CleanupConfiguration?) async throws -> String {
        let models = [primary, primary?.matches(fallback) == true ? nil : fallback].compactMap { $0 }.filter(\.isConfigured)
        guard !models.isEmpty else { throw MobileDictationError.selectionNeedsTextModel }
        let editor = SelectionEditor(session: session)
        for model in models {
            try Task.checkCancellation()
            if let result = await editor.edit(selection: selection, instruction: instruction, configuration: model) {
                try Task.checkCancellation()
                return result.text
            }
        }
        throw MobileDictationError.selectionEditFailed
    }

    func prepare(_ transcript: MobileRecognition.Result, target: String?, correct: Bool,
                 primary: CleanupConfiguration?, fallback: CleanupConfiguration?) async -> Result {
        guard target != nil || correct else { return Result(text: transcript.text) }
        let source = TextLanguage.source(in: transcript.text, reported: transcript.language)
        if let target, source != target {
            let translated = await Translator(session: session).translate(
                transcript.text, to: target, configuration: primary, fallback: fallback,
                sourceLanguage: source, correctRecognition: correct
            )
            return Result(text: translated.text, translationFailed: !translated.translated)
        }
        guard correct else { return Result(text: transcript.text) }
        let cleaned = await CleanupPipeline(session: session).clean(
            transcript.text, sourceLanguage: source, configuration: primary, fallback: fallback
        )
        return Result(text: cleaned.text)
    }
}
