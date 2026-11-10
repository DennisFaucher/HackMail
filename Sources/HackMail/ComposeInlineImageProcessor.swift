import AppKit
import Foundation

enum ComposeInlineImageProcessor {
    static let maximumInlineImageBytes = 4 * 1024 * 1024

    private struct InlineImage {
        let range: NSRange
        let marker: String
        let data: Data
    }

    static func process(_ attributedBody: NSAttributedString) throws -> OutgoingEmailBody {
        let fullRange = NSRange(location: 0, length: attributedBody.length)
        var attachments: [(range: NSRange, attachment: NSTextAttachment)] = []
        attributedBody.enumerateAttribute(.attachment, in: fullRange) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            attachments.append((range, attachment))
        }

        var totalImageBytes = 0
        var inlineImages: [InlineImage] = []
        for (index, item) in attachments.enumerated() {
            let data = try pngData(for: item.attachment)
            guard totalImageBytes + data.count <= maximumInlineImageBytes else {
                throw ComposeInlineImageError.exceedsSizeLimit
            }
            totalImageBytes += data.count
            inlineImages.append(
                InlineImage(
                    range: item.range,
                    marker: "HACKMAIL_INLINE_IMAGE_\(index)_\(UUID().uuidString)",
                    data: data
                )
            )
        }

        let html: String
        if inlineImages.isEmpty {
            html = htmlRepresentation(of: attributedBody)
            return OutgoingEmailBody(plainText: attributedBody.string, html: html)
        }

        let mutableBody = NSMutableAttributedString(attributedString: attributedBody)
        for image in inlineImages.reversed() {
            var attributes = attributedBody.attributes(at: image.range.location, effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            mutableBody.replaceCharacters(
                in: image.range,
                with: NSAttributedString(string: image.marker, attributes: attributes)
            )
        }

        var htmlBody = htmlRepresentation(of: mutableBody)
        var plainText = mutableBody.string
        for image in inlineImages {
            let dataURL = "data:image/png;base64,\(image.data.base64EncodedString())"
            htmlBody = htmlBody.replacingOccurrences(
                of: image.marker,
                with: "<img src=\"\(dataURL)\" alt=\"Pasted image\">"
            )
            plainText = plainText.replacingOccurrences(of: image.marker, with: "[Inline image]")
        }
        return OutgoingEmailBody(plainText: plainText, html: htmlBody)
    }

    private static func htmlRepresentation(of attributedBody: NSAttributedString) -> String {
        guard let data = try? attributedBody.data(
            from: NSRange(location: 0, length: attributedBody.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
        ), let html = String(data: data, encoding: .utf8) else {
            return "<pre>\(EmailHTMLSanitizer.escapeText(attributedBody.string))</pre>"
        }
        return EmailHTMLSanitizer.bodyFragment(html)
    }

    private static func pngData(for attachment: NSTextAttachment) throws -> Data {
        let sourceData = attachment.fileWrapper?.regularFileContents ?? attachment.contents
        guard let image = attachment.image ?? sourceData.flatMap(NSImage.init(data:)),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw ComposeInlineImageError.unsupportedImage
        }
        return pngData
    }
}

private enum ComposeInlineImageError: LocalizedError {
    case unsupportedImage
    case exceedsSizeLimit

    var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            "A pasted image could not be prepared. Try copying it again or attach the image file instead."
        case .exceedsSizeLimit:
            "Pasted inline images exceed the 4 MiB total limit. Resize or remove an image before sending."
        }
    }
}
