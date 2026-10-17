/// M1-A bounded duplicate-key preflight (SPEC §5). Foundation decoding
/// cannot see duplicate object keys, so this small owned byte scanner runs
/// first: it rejects duplicate keys at every nesting level (comparing
/// `\u`-unescaped scalars, so `"\u0061lias"` equals `"alias"`), enforces
/// the nesting bound, rejects BOM/trailing-garbage/truncation, and records
/// the byte ranges of `request_options` values for the size check and raw
/// retention. It never builds a value tree: only a key stack bounded by the
/// nesting depth is retained.
public struct PreflightResult: Sendable {
    /// Full field paths (`$.models[0].request_options`) to source ranges.
    public var requestOptionsRanges: [String: Range<Int>]

    public init(requestOptionsRanges: [String: Range<Int>] = [:]) {
        self.requestOptionsRanges = requestOptionsRanges
    }
}

public func scanJSONStructure(_ bytes: [UInt8]) throws -> PreflightResult {
    guard String(bytes: bytes, encoding: .utf8) != nil else {
        throw ConfigError(
            path: "$", kind: .unsupportedPathEncoding,
            message: "configuration is not valid UTF-8.",
            hint: "re-encode the file as UTF-8 without a BOM.")
    }
    var parser = PreflightParser(bytes: bytes)
    return try parser.parse()
}

private enum PathSegment: Sendable {
    case key(String)
    case index(Int)
}

private struct PreflightParser {
    let bytes: [UInt8]
    var index: Int = 0
    var path: [PathSegment] = []
    var requestOptionsRanges: [String: Range<Int>] = [:]

    mutating func parse() throws -> PreflightResult {
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            throw ConfigError(
                path: "$", kind: .unsupportedFormat,
                message: "leading UTF-8 BOM is not strict JSON.",
                hint: "save the file as plain UTF-8 without a BOM.")
        }
        skipWhitespace()
        _ = try parseValue(depth: 0)
        skipWhitespace()
        if index != bytes.count {
            throw ConfigError(
                path: pathString(), kind: .malformedJSON,
                message: "trailing bytes after the top-level value.",
                hint: "the file must contain exactly one JSON value.")
        }
        return PreflightResult(requestOptionsRanges: requestOptionsRanges)
    }

    mutating func pathString() -> String {
        var out = "$"
        for segment in path {
            switch segment {
            case .key(let key): out += ".\(key)"
            case .index(let i): out += "[\(i)]"
            }
        }
        return out
    }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    mutating func parseValue(depth: Int) throws -> Range<Int> {
        guard depth <= ConfigLimits.maxNestingDepth else {
            throw ConfigError(
                path: pathString(), kind: .limitExceeded,
                message: "nesting exceeds \(ConfigLimits.maxNestingDepth) levels.",
                hint: "flatten the configuration; deep nesting is rejected before decoding.")
        }
        guard index < bytes.count else {
            throw ConfigError(
                path: pathString(), kind: .malformedJSON,
                message: "unexpected end of input.",
                hint: "the JSON value is truncated.")
        }
        let start = index
        switch bytes[index] {
        case 0x7B: // {
            _ = try parseObject(depth: depth)
        case 0x5B: // [
            _ = try parseArray(depth: depth)
        case 0x22: // "
            _ = try parseString()
        case 0x74, 0x66, 0x6E: // t f n
            try parseLiteral()
        case 0x2D, 0x30...0x39: // - 0-9
            try parseNumber()
        default:
            throw ConfigError(
                path: pathString(), kind: .malformedJSON,
                message: "unexpected byte 0x\(String(bytes[index], radix: 16)) in value position.",
                hint: "check for stray commas, comments or single quotes (strict JSON only).")
        }
        return start..<index
    }

    mutating func parseObject(depth: Int) throws {
        index += 1 // {
        // Byte-exact key identity (CFG-05): decoded keys compare as UTF-8
        // bytes so no Unicode normalization can merge or split them. Pairs
        // that are byte-distinct but canonically equivalent are refused
        // loudly for the same reason (a decoded dictionary could not hold
        // both without silent merging).
        var seenBytes: Set<[UInt8]> = []
        var seenCanonical: Set<String> = []
        skipWhitespace()
        if peek == 0x7D { index += 1; return }
        while true {
            skipWhitespace()
            guard peek == 0x22 else {
                throw ConfigError(
                    path: pathString(), kind: .malformedJSON,
                    message: "object keys must be strings.",
                    hint: "quote the key.")
            }
            let key = try parseString()
            if seenBytes.contains(Array(key.utf8)) {
                throw ConfigError(
                    path: pathString() + ".\(key)", kind: .duplicateKey,
                    message: "duplicate object key '\(key)'.",
                    hint: "keep exactly one entry; first-wins and last-wins are both rejected.")
            }
            if !seenCanonical.insert(key).inserted {
                throw ConfigError(
                    path: pathString() + ".\(key)", kind: .duplicateKey,
                    message: "object key '\(key)' is canonically equivalent to an earlier key under Unicode.",
                    hint: "rename to differ beyond normalization; merging is never silent.")
            }
            seenBytes.insert(Array(key.utf8))
            skipWhitespace()
            try expectByte(0x3A) // :
            skipWhitespace()
            path.append(.key(key))
            let valueRange = try parseValue(depth: depth + 1)
            if key == "request_options" {
                requestOptionsRanges[pathString()] = valueRange
            }
            path.removeLast()
            skipWhitespace()
            if peek == 0x2C { index += 1; continue } // ,
            if peek == 0x7D { index += 1; return } // }
            throw ConfigError(
                path: pathString(), kind: .malformedJSON,
                message: "expected ',' or '}' in object.",
                hint: "check commas between entries.")
        }
    }

    mutating func parseArray(depth: Int) throws {
        index += 1 // [
        var count = 0
        skipWhitespace()
        if peek == 0x5D { index += 1; return }
        while true {
            skipWhitespace()
            path.append(.index(count))
            _ = try parseValue(depth: depth + 1)
            path.removeLast()
            count += 1
            skipWhitespace()
            if peek == 0x2C { index += 1; continue }
            if peek == 0x5D { index += 1; return }
            throw ConfigError(
                path: pathString(), kind: .malformedJSON,
                message: "expected ',' or ']' in array.",
                hint: "check commas between elements.")
        }
    }

    var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func expectByte(_ byte: UInt8) throws {
        guard peek == byte else {
            throw ConfigError(
                path: pathString(), kind: .malformedJSON,
                message: "expected '\(UnicodeScalar(byte))' here.",
                hint: "check punctuation around this path.")
        }
        index += 1
    }

    /// Parses a JSON string, returning decoded scalars. Surrogate pairs are
    /// combined before comparison so encoded duplicates cannot escape;
    /// lone surrogates, bad escapes and raw control bytes are malformed.
    mutating func parseString() throws -> String {
        index += 1 // opening "
        var out = ""
        var chunkStart = index
        while true {
            guard index < bytes.count else {
                throw ConfigError(
                    path: pathString(), kind: .malformedJSON,
                    message: "unterminated string.",
                    hint: "close the quote.")
            }
            let byte = bytes[index]
            switch byte {
            case 0x22: // closing "
                out += String(decoding: bytes[chunkStart..<index], as: UTF8.self)
                index += 1
                return out
            case 0x5C: // backslash
                out += String(decoding: bytes[chunkStart..<index], as: UTF8.self)
                index += 1
                out += try parseEscape()
                chunkStart = index
            case 0x00...0x1F:
                throw ConfigError(
                    path: pathString(), kind: .malformedJSON,
                    message: "unescaped control byte in string.",
                    hint: "escape it as \\u00XX.")
            default:
                index += 1
            }
        }
    }

    mutating func parseEscape() throws -> String {
        guard index < bytes.count else {
            throw ConfigError(
                path: pathString(), kind: .malformedJSON,
                message: "truncated escape sequence.",
                hint: "finish the escape.")
        }
        let byte = bytes[index]
        index += 1
        switch byte {
        case 0x22: return "\""
        case 0x5C: return "\\"
        case 0x2F: return "/"
        case 0x62: return "\u{08}"
        case 0x66: return "\u{0C}"
        case 0x6E: return "\n"
        case 0x72: return "\r"
        case 0x74: return "\t"
        case 0x75: // uXXXX, with surrogate-pair combination
            let high = try parseHex4()
            if high >= 0xD800 && high <= 0xDBFF {
                guard index + 6 <= bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
                    throw ConfigError(
                        path: pathString(), kind: .malformedJSON,
                        message: "lone high surrogate in \\u escape.",
                        hint: "complete the surrogate pair.")
                }
                index += 2
                let low = try parseHex4()
                guard low >= 0xDC00 && low <= 0xDFFF else {
                    throw ConfigError(
                        path: pathString(), kind: .malformedJSON,
                        message: "lone high surrogate in \\u escape.",
                        hint: "complete the surrogate pair.")
                }
                let scalar = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                return String(Unicode.Scalar(scalar)!)
            }
            if high >= 0xDC00 && high <= 0xDFFF {
                throw ConfigError(
                    path: pathString(), kind: .malformedJSON,
                    message: "lone low surrogate in \\u escape.",
                    hint: "complete the surrogate pair.")
            }
            return String(Unicode.Scalar(high)!)
        default:
            throw ConfigError(
                path: pathString(), kind: .malformedJSON,
                message: "invalid escape \\(UnicodeScalar(byte)).",
                hint: "use one of \" \\ / b f n r t u.")
        }
    }

    mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else {
            throw ConfigError(
                path: pathString(), kind: .malformedJSON,
                message: "truncated \\u escape.",
                hint: "provide four hex digits.")
        }
        var value: UInt32 = 0
        for offset in 0..<4 {
            let byte = bytes[index + offset]
            let digit: UInt32
            switch byte {
            case 0x30...0x39: digit = UInt32(byte - 0x30)
            case 0x41...0x46: digit = UInt32(byte - 0x41) + 10
            case 0x61...0x66: digit = UInt32(byte - 0x61) + 10
            default:
                throw ConfigError(
                    path: pathString(), kind: .malformedJSON,
                    message: "non-hex digit in \\u escape.",
                    hint: "provide four hex digits.")
            }
            value = value * 16 + digit
        }
        index += 4
        return value
    }

    mutating func parseLiteral() throws {
        for word in ["true", "false", "null"] {
            let wordBytes = Array(word.utf8)
            if bytes.count - index >= wordBytes.count,
               bytes[index..<(index + wordBytes.count)].elementsEqual(wordBytes) {
                index += wordBytes.count
                return
            }
        }
        throw ConfigError(
            path: pathString(), kind: .malformedJSON,
            message: "invalid literal; expected true, false or null.",
            hint: "lowercase literals only, no bare words.")
    }

    mutating func parseNumber() throws {
        // -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
        if peek == 0x2D { index += 1 }
        guard let digit = peek, digit >= 0x30, digit <= 0x39 else {
            throw ConfigError(
                path: pathString(), kind: .malformedJSON,
                message: "invalid number.",
                hint: "numbers need at least one digit.")
        }
        if digit == 0x30 {
            index += 1
            if let next = peek, next >= 0x30, next <= 0x39 {
                throw ConfigError(
                    path: pathString(), kind: .malformedJSON,
                    message: "leading zeros are not strict JSON.",
                    hint: "write 0, not 01.")
            }
        } else {
            while let next = peek, next >= 0x30, next <= 0x39 { index += 1 }
        }
        if peek == 0x2E {
            index += 1
            guard let first = peek, first >= 0x30, first <= 0x39 else {
                throw ConfigError(
                    path: pathString(), kind: .malformedJSON,
                    message: "a fraction needs digits after '.'.",
                    hint: "write 1.0, not 1.")
            }
            while let next = peek, next >= 0x30, next <= 0x39 { index += 1 }
        }
        if peek == 0x65 || peek == 0x45 {
            index += 1
            if peek == 0x2B || peek == 0x2D { index += 1 }
            guard let first = peek, first >= 0x30, first <= 0x39 else {
                throw ConfigError(
                    path: pathString(), kind: .malformedJSON,
                    message: "an exponent needs digits.",
                    hint: "write 1e3, not 1e.")
            }
            while let next = peek, next >= 0x30, next <= 0x39 { index += 1 }
        }
    }
}
