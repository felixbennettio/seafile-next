import Foundation

public struct DocumentComment: Decodable, Identifiable, Sendable {
    public let id: Int, comment: String, resolved: Bool
    public let user_name: String?, user_email: String?, created_at: String?
    public let replies: [DocumentReply]?
}
public struct DocumentReply: Decodable, Identifiable, Sendable {
    public let id: Int, reply: String
    public let user_name: String?, user_email: String?, created_at: String?
}
public struct DocumentCommentPage: Decodable, Sendable {
    public let comments: [DocumentComment], total_count: Int
}

extension SeafileAPI {
    private func commentsPath(repo: String, document: String, comment: Int? = nil) throws -> String {
        guard UUID(uuidString: repo) != nil, UUID(uuidString: document) != nil,
              comment.map({ $0 > 0 }) ?? true else { throw SeafileError.invalidResponse }
        return "api/v2.1/repos/\(repo)/file/\(document)/comments/" + (comment.map { "\($0)/" } ?? "")
    }
    public func documentComments(repo: String, document: String, page: Int = 1, resolved: Bool? = nil) async throws -> DocumentCommentPage {
        guard page > 0 else { throw SeafileError.invalidResponse }
        var query: [URLQueryItem] = [.init(name: "page", value: String(page)), .init(name: "per_page", value: "25")]
        if let resolved { query.append(.init(name: "resolved", value: resolved ? "true" : "false")) }
        let result = try JSONDecoder().decode(DocumentCommentPage.self, from: await request(commentsPath(repo: repo, document: document), query: query))
        guard result.total_count >= 0, Set(result.comments.map(\.id)).count == result.comments.count,
              result.comments.allSatisfy({ comment in
                  let replies = comment.replies ?? []
                  return comment.id > 0 && replies.allSatisfy({ $0.id > 0 }) && Set(replies.map(\.id)).count == replies.count
              }) else { throw SeafileError.invalidResponse }
        return result
    }
    public func addDocumentComment(repo: String, document: String, text: String) async throws {
        _ = try await request(commentsPath(repo: repo, document: document), method: "POST", form: ["comment": try CommentText.html(text)])
    }
    public func replyToDocumentComment(repo: String, document: String, comment: Int, text: String) async throws {
        _ = try await request(commentsPath(repo: repo, document: document, comment: comment) + "replies/", method: "POST", form: ["reply": try CommentText.html(text), "type": "reply"])
    }
    public func editDocumentComment(repo: String, document: String, comment: Int, text: String) async throws {
        _ = try await request(commentsPath(repo: repo, document: document, comment: comment), method: "PUT", form: ["comment": try CommentText.html(text)])
    }
    public func resolveDocumentComment(repo: String, document: String, comment: Int, resolved: Bool) async throws {
        _ = try await request(commentsPath(repo: repo, document: document, comment: comment), method: "PUT", form: ["resolved": resolved ? "true" : "false"])
    }
    public func deleteDocumentComment(repo: String, document: String, comment: Int) async throws {
        _ = try await request(commentsPath(repo: repo, document: document, comment: comment), method: "DELETE")
    }
    public func editDocumentReply(repo: String, document: String, comment: Int, reply: Int, text: String) async throws {
        guard reply > 0 else { throw SeafileError.invalidResponse }
        _ = try await request(commentsPath(repo: repo, document: document, comment: comment) + "replies/\(reply)/", method: "PUT", form: ["reply": try CommentText.html(text)])
    }
    public func deleteDocumentReply(repo: String, document: String, comment: Int, reply: Int) async throws {
        guard reply > 0 else { throw SeafileError.invalidResponse }
        _ = try await request(commentsPath(repo: repo, document: document, comment: comment) + "replies/\(reply)/", method: "DELETE")
    }
}

/// Comments are HTML on the server. Native plain-text input must be escaped;
/// native summaries never render server HTML or fetch remote image resources.
public enum CommentText {
    public static func html(_ text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 65_536,
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw SeafileError.local("Enter a comment of up to 64 KB.") }
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return "<p>" + escaped.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>") + "</p>"
    }
    public static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</p\s*>|</div\s*>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        let entities = ["lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "amp": "&"]
        if let expression = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|lt|gt|quot|apos|nbsp|amp);"#) {
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let numberRange = Range(match.range(at: 1), in: text), let fullRange = Range(match.range, in: text) else { continue }
                let number = String(text[numberRange])
                if let replacement = entities[number] { text.replaceSubrange(fullRange, with: replacement) }
                else {
                    let value = number.hasPrefix("#x") ? UInt32(number.dropFirst(2), radix: 16) : UInt32(number.dropFirst())
                    if let value, let scalar = UnicodeScalar(value), value != 0 { text.replaceSubrange(fullRange, with: String(scalar)) }
                }
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func canEdit(_ html: String) -> Bool {
        // Preserve mentions, attachments and inline formatting by sending users
        // to the full editor rather than flattening an existing rich comment.
        html.range(of: #"<(?!/?p\b|br\b|/br\b)[^>]+>"#, options: [.regularExpression, .caseInsensitive]) == nil
    }
}
