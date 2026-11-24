import Foundation

struct SelectionEditOutcome: Sendable {
    /// The text that replaces the selection. Empty means the selection is removed.
    let text: String
}

/// Turns "selected text + spoken words" into the replacement text.
///
/// The spoken words may be an instruction about the selection ("translate this
/// to English", "fix the mistakes", "remove it") or the replacement itself. One
/// model call decides and applies it; the selection is replaced with the answer.
final class SelectionEditor {
    private var session: URLSession { SharedSession.cloud }

    func edit(selection: String,
              instruction: String,
              configuration: CleanupConfiguration) async -> SelectionEditOutcome? {
        let selected = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty, !spoken.isEmpty, selected.count <= 8_000 else { return nil }

        guard let spec = ProviderCatalog.spec(configuration.provider) else { return nil }
        let key = ProviderCatalog.key(for: spec)
        if spec.requiresKey, key == nil { return nil }

        let base = configuration.provider == "openai" ? configuration.baseURL : spec.baseURL
        guard let url = spec.endpoint("chat/completions", baseURL: base) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(6, configuration.timeout + 4)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        spec.setHeaders(on: &request, key: key)

        let payload: [String: Any] = [
            "model": configuration.model,
            "temperature": 0,
            "max_tokens": 4096,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": "SELECTED TEXT:\n\(selected)\n\nSPOKEN:\n\(spoken)"],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let preparedRequest = request
        guard let answer = try? await withTimeout(max(6, configuration.timeout + 4), operation: {
            try await Self.send(preparedRequest, session: self.session)
        }) else { return nil }

        return Self.validatedAnswer(answer, selection: selected, instruction: spoken)
    }

    static func validatedAnswer(_ answer: String, selection: String, instruction: String) -> SelectionEditOutcome? {
        guard let result = normalize(answer, selection: selection) else { return nil }
        if !result.text.isEmpty {
            return isEchoOfCommand(answer, instruction: instruction) ? nil : result
        }

        // Only a clear request for complete deletion can remove the whole selection.
        // Видаляємо все виділення лише за однозначною командою повного видалення.
        let words = instruction.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        let command = words.joined(separator: " ")
        let deletionCommands: Set<String> = [
            "delete", "delete it", "delete this", "delete selected text", "delete the selection",
            "please delete it", "remove", "remove it", "remove this", "remove the selection",
            "видали", "видали це", "видали виділення", "видали виділений текст", "прибери це",
            "удали", "удали это", "удали выделение", "удали выделенный текст",
        ]
        return deletionCommands.contains(command) ? result : nil
    }

    /// Parses the model answer. `DELETE` means the selection must be removed;
    /// an empty answer is a failure, not a deletion.
    private static let commandVerbs = [
        "переведи", "переклади", "переведи", "translate", "исправь", "виправ", "fix",
        "удали", "видали", "delete", "remake", "перепиши", "rewrite", "сократи", "скороти",
        "summar", "перефразуй", "paraphrase",
    ]

    /// True when the spoken words were a command and the model simply repeated
    /// them instead of applying the command.
    static func isEchoOfCommand(_ answer: String, instruction: String) -> Bool {
        let a = answer.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let i = instruction.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !i.isEmpty else { return false }
        guard commandVerbs.contains(where: { i.contains($0) }) else { return false }
        return a == i || a.hasPrefix(i) || i.hasPrefix(a)
    }

    static func normalize(_ raw: String, selection: String) -> SelectionEditOutcome? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.uppercased() == "DELETE" { return SelectionEditOutcome(text: "") }

        let wrappers: [(Character, Character)] = [("\"", "\""), ("«", "»"), ("“", "”"), ("`", "`")]
        for (opening, closing) in wrappers {
            if text.count > 2, text.first == opening, text.last == closing {
                text = String(text.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard !text.isEmpty else { return nil }

        // A rewrite can be much shorter (summarise) or longer (expand), but not
        // to the point of losing the content entirely.
        let ratio = Double(text.count) / Double(max(1, selection.count))
        guard ratio >= 0.15, ratio <= 4.0 else { return nil }

        return SelectionEditOutcome(text: text)
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> String {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RecognitionError.failed("Selection edit failed")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw RecognitionError.failed("Unexpected selection edit response")
        }
        return content
    }

    static let systemPrompt = """
    You edit a piece of text that the user selected, according to what the user said.

    The user's spoken words are either:
    - an instruction about the selected text (translate, fix spelling, shorten, rewrite, change tone, remove, ...), or
    - the text that should replace the selection.

    Decide which one it is and produce the final text that should replace the selection.

    Rules:
    - Return ONLY the replacement text. No quotes, no explanations, no preamble.
    - If the selection must be removed, return exactly DELETE and nothing else.
    - If the spoken words are a command, apply it; do not answer or comment on it.
    - Keep names, numbers, technical terms, code and URLs exactly as they are, unless the instruction changes them.
    - Keep the language of the selected text unless the instruction asks for another language.
    - If the selection is already correct and nothing should change, return it unchanged.
    """
}
