import Combine
import Foundation

struct LanguageToolReplacement: Decodable, Equatable, Identifiable, Sendable {
    let value: String
    var id: String { value }
}

struct LanguageToolMatch: Decodable, Equatable, Identifiable, Sendable {
    struct Context: Decodable, Equatable, Sendable {
        let text: String
    }

    struct Rule: Decodable, Equatable, Sendable {
        let id: String?
    }

    let message: String
    let offset: Int
    let length: Int
    let replacements: [LanguageToolReplacement]
    let context: Context?
    let rule: Rule?

    var id: String { "\(offset):\(length):\(rule?.id ?? message)" }
}

struct LanguageToolResponse: Decodable {
    let matches: [LanguageToolMatch]
}

private enum LanguageToolError: LocalizedError {
    case invalidURL
    case rejected(Int)
    case invalidResponse
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid HTTPS LanguageTool server URL."
        case .rejected(let status): "LanguageTool returned HTTP \(status)."
        case .invalidResponse: "LanguageTool returned an unreadable response."
        case .responseTooLarge: "LanguageTool returned a response larger than HackMail accepts."
        }
    }
}

/// Refuses any redirect that is not HTTPS, so draft text can never be re-sent over plain HTTP.
private final class HTTPSOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url?.scheme?.lowercased() == "https" ? request : nil
    }
}

struct LanguageToolClient: Sendable {
    static let maximumResponseBytes = 2 * 1024 * 1024

    func check(text: String, baseURL: String, language: String) async throws -> [LanguageToolMatch] {
        guard let endpoint = Self.checkEndpoint(from: baseURL) else { throw LanguageToolError.invalidURL }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "language", value: language.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        // Ephemeral session: no cookies, credentials, or disk cache for draft-related traffic.
        let session = URLSession(configuration: .ephemeral, delegate: HTTPSOnlyRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw LanguageToolError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw LanguageToolError.rejected(response.statusCode) }
        guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw LanguageToolError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= Self.maximumResponseBytes else { throw LanguageToolError.responseTooLarge }
        }
        return try JSONDecoder().decode(LanguageToolResponse.self, from: data).matches
    }

    static func checkEndpoint(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else { return nil }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, "check"].filter { !$0.isEmpty }.joined(separator: "/")
        return components.url
    }
}

@MainActor
final class LanguageToolChecker: ObservableObject {
    static let maximumTextLength = 20_000

    @Published private(set) var matches: [LanguageToolMatch] = []
    @Published private(set) var isChecking = false
    @Published private(set) var hasChecked = false
    @Published private(set) var errorMessage: String?

    private var task: Task<Void, Never>?
    private var requestID = UUID()

    func scheduleCheck(text: String, enabled: Bool, baseURL: String, language: String) {
        task?.cancel()
        requestID = UUID()
        let currentRequestID = requestID
        matches = []
        isChecking = false
        hasChecked = false
        errorMessage = nil

        guard enabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard text.utf16.count <= Self.maximumTextLength else {
            errorMessage = "LanguageTool checks are limited to 20,000 characters per draft."
            return
        }

        task = Task { [weak self] in
            defer {
                if let self, self.requestID == currentRequestID {
                    self.isChecking = false
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled, let self, self.requestID == currentRequestID else { return }
                self.isChecking = true
                let matches = try await LanguageToolClient().check(text: text, baseURL: baseURL, language: language)
                guard !Task.isCancelled, self.requestID == currentRequestID else { return }
                self.matches = Array(matches.prefix(100))
                self.hasChecked = true
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.requestID == currentRequestID else { return }
                self.errorMessage = "LanguageTool could not check this draft. Check the server URL and connection."
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        requestID = UUID()
        isChecking = false
    }
}
