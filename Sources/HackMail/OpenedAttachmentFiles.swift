import Foundation

enum OpenedAttachmentFiles {
    private static let sessionDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HackMail-OpenAttachments-\(UUID().uuidString)", isDirectory: true)

    static func write(_ data: Data, fileName: String) throws -> URL {
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let safeName = URL(fileURLWithPath: fileName).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let destination = sessionDirectory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func cleanup() {
        try? FileManager.default.removeItem(at: sessionDirectory)
    }
}
