import Foundation

enum IMAPMailboxNameCodec {
    static func decode(_ value: String) -> String {
        var result = ""
        var cursor = value.startIndex
        while cursor < value.endIndex {
            guard value[cursor] == "&" else {
                result.append(value[cursor])
                cursor = value.index(after: cursor)
                continue
            }
            guard let terminator = value[cursor...].firstIndex(of: "-") else {
                result.append("&")
                cursor = value.index(after: cursor)
                continue
            }
            let encoded = String(value[value.index(after: cursor)..<terminator])
            if encoded.isEmpty {
                result.append("&")
            } else {
                var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                while !base64.count.isMultiple(of: 4) { base64.append("=") }
                if let data = Data(base64Encoded: base64),
                   let decoded = String(data: data, encoding: .utf16BigEndian) {
                    result.append(decoded)
                } else {
                    result.append(String(value[cursor...terminator]))
                }
            }
            cursor = value.index(after: terminator)
        }
        return result
    }
}
