import Combine
import Foundation

@MainActor
final class Stage7PunctuationSuggester: ObservableObject {
    @Published private(set) var suggestion = ""
    @Published private(set) var isLoading = false
    @Published private(set) var failure: String?

    private let model = "qwen3:14b"
    private let prompt = """
    Ты редактор пунктуации русского ASR. Верни только исходный текст с исправленными знаками препинания, регистром и троеточиями. Нельзя добавлять, удалять, заменять или переставлять слова, числа и термины. Без пояснений.

    Текст:
    """

    func suggest(for text: String) async {
        guard !text.isEmpty, !isLoading else { return }
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            let payload: [String: Any] = [
                "model": model, "prompt": prompt + text, "stream": false,
                "options": ["temperature": 0, "num_ctx": 4096, "num_predict": 1024],
            ]
            var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 180
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidate = json["response"] as? String
            else { throw CocoaError(.fileReadCorruptFile) }
            guard punctuationOnly(candidate, comparedTo: text) else {
                failure = "Suggestion changed words or numbers, so it was rejected."
                return
            }
            suggestion = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            failure = "Punctuation suggestion failed: \(error.localizedDescription)"
        }
    }

    private func punctuationOnly(_ candidate: String, comparedTo original: String) -> Bool {
        tokens(candidate) == tokens(original)
    }

    private func tokens(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber && $0 != "+" && $0 != "#" && $0 != "*" }
            .map(String.init)
    }
}
