import Foundation
import UniformTypeIdentifiers

enum AttachmentLoader {
    static func load(urls: [URL], existingBytes: Int, maxBytes: Int) throws -> [MailAttachment] {
        var loaded: [MailAttachment] = []
        var totalBytes = existingBytes
        for url in urls {
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer { if hasScopedAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                guard values.isDirectory != true else { throw AttachmentError.notAFile }
                if let fileSize = values.fileSize, totalBytes + fileSize > maxBytes {
                    throw AttachmentError.tooLarge(maxBytes)
                }
                let data = try Data(contentsOf: url)
                totalBytes += data.count
                guard totalBytes <= maxBytes else { throw AttachmentError.tooLarge(maxBytes) }
                let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                loaded.append(MailAttachment(id: UUID(), fileName: url.lastPathComponent, mimeType: mimeType, data: data))
            } catch let error as AttachmentError {
                throw error
            } catch {
                throw AttachmentError.couldNotRead(url.lastPathComponent)
            }
        }
        return loaded
    }
}

enum AttachmentError: LocalizedError {
    case notAFile
    case tooLarge(Int)
    case couldNotRead(String)

    var errorDescription: String? {
        switch self {
        case .notAFile: "Choose files, not folders."
        case .tooLarge(let maxBytes): "Attachments exceed the \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)) total size limit."
        case .couldNotRead(let name): "Could not read \(name). Check that the file is available and try again."
        }
    }
}
