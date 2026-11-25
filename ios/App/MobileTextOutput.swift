import Foundation

struct MobileTextOutput {
    struct Result: Equatable {
        let text: String
        var translationFailed = false
    }

    var session: URLSession = SharedSession.cloud
    var configuration = MobileGateway.textConfiguration

    func editSelection(_ selection: String, instruction: String) async throws -> String {
        guard configuration.isConfigured else { throw MobileDictationError.gatewayNotProvisioned }
        try Task.checkCancellation()
        let editor = SelectionEditor(session: session)
        let result = try await editor.edit(selection: selection, instruction: instruction, configuration: configuration)
        try Task.checkCancellation()
        guard let result else { throw MobileDictationError.selectionEditFailed }
        return result.text
    }

    func prepare(_ transcript: MobileRecognition.Result, target: String?, correct: Bool = true) async -> Result {
        guard target != nil || correct else { return Result(text: transcript.text) }
        let source = TextLanguage.source(in: transcript.text, reported: transcript.language)
        if let target, source != target {
            let translated = await Translator(session: session).translate(
                transcript.text, to: target, configuration: configuration,
                sourceLanguage: source, correctRecognition: correct
            )
            return Result(text: translated.text, translationFailed: !translated.translated)
        }
        guard correct else { return Result(text: transcript.text) }
        let cleaned = await CleanupPipeline(session: session).clean(
            transcript.text, sourceLanguage: source, configuration: configuration
        )
        return Result(text: cleaned.text)
    }
}
