import Foundation

/// Picks a command's output out of the console stream: after the echoed
/// command line, up to the next shell prompt. Firmwares name their prompt
/// after the core ("ap> "), so any short "<word>> " at the start of a line
/// counts.
public enum NSHOutput {
    static let promptPattern = try! NSRegularExpression(pattern: "(?m)^[A-Za-z0-9_.-]{1,16}> ")

    public static func strip(_ text: String) -> String {
        // drop ANSI escape sequences and carriage returns
        var out = ""
        var it = text.unicodeScalars.makeIterator()
        while let c = it.next() {
            if c == "\u{1B}" {
                if let n = it.next(), n == "[" {
                    while let k = it.next(), !(("@"..."~").contains(k)) {}
                }
                continue
            }
            if c != "\r" { out.unicodeScalars.append(c) }
        }
        return out
    }

    static func afterEcho(_ text: String, command: String) -> Substring? {
        let t = strip(text)
        guard let r = t.range(of: command) else { return nil }
        guard let nl = t[r.upperBound...].firstIndex(of: "\n") else { return nil }
        return t[t.index(after: nl)...]
    }

    static func promptRange(in s: Substring) -> Range<String.Index>? {
        let str = String(s)
        guard let m = promptPattern.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
              let r = Range(m.range, in: str) else { return nil }
        let lower = s.index(s.startIndex, offsetBy: str.distance(from: str.startIndex, to: r.lowerBound))
        let upper = s.index(lower, offsetBy: str.distance(from: r.lowerBound, to: r.upperBound))
        return lower..<upper
    }

    public static func isComplete(_ text: String, command: String) -> Bool {
        guard let rest = afterEcho(text, command: command) else { return false }
        return promptRange(in: rest) != nil
    }

    public static func body(_ text: String, command: String) -> String {
        guard let rest = afterEcho(text, command: command) else { return strip(text) }
        let end = promptRange(in: rest)?.lowerBound ?? rest.endIndex
        return String(rest[..<end]).trimmingCharacters(in: .newlines)
    }
}
