import Foundation

/// application/x-www-form-urlencoded со строгим percent-encoding:
/// всё, кроме `A–Z a–z 0–9 - . _ ~`, кодируется (в том числе `+ & = ` и пробел).
enum FormEncoding {
    private static let unreserved: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s
    }()

    static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { escape($0.0) + "=" + escape($0.1) }.joined(separator: "&")
    }
}
