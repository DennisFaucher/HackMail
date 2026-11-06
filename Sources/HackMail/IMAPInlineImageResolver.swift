import Foundation

enum IMAPInlineImageResolver {
    static func replacingCIDReferences(in html: String, with dataURLs: [String: String]) -> String {
        var resolved = html
        for (contentID, dataURL) in dataURLs {
            resolved = resolved.replacingOccurrences(of: "cid:<\(contentID)>", with: dataURL, options: .caseInsensitive)
            resolved = resolved.replacingOccurrences(of: "cid:\(contentID)", with: dataURL, options: .caseInsensitive)
        }
        return resolved
    }
}
