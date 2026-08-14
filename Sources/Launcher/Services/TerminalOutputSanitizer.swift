/// Converts terminal-oriented process output into safe, plain text suitable for
/// display in a `Text` view.
///
/// The parser deliberately retains only constant-size state. In particular,
/// control-string payloads are discarded as they arrive instead of being
/// accumulated while waiting for their terminator.
struct TerminalOutputSanitizer {
    private enum State {
        case text
        case escape
        case escapeIntermediate
        case csi
        case controlString
        case controlStringEscape
    }

    private enum CodePoint {
        static let nul: UInt32 = 0x00
        static let bell: UInt32 = 0x07
        static let tab: UInt32 = 0x09
        static let lineFeed: UInt32 = 0x0A
        static let carriageReturn: UInt32 = 0x0D
        static let escape: UInt32 = 0x1B
        static let delete: UInt32 = 0x7F

        // Eight-bit (C1) forms of the ANSI string/control introducers.
        static let dcs: UInt32 = 0x90
        static let sos: UInt32 = 0x98
        static let csi: UInt32 = 0x9B
        static let stringTerminator: UInt32 = 0x9C
        static let osc: UInt32 = 0x9D
        static let pm: UInt32 = 0x9E
        static let apc: UInt32 = 0x9F
    }

    private var state: State = .text
    private var hasPendingCarriageReturn = false

    /// Sanitizes the next output chunk. The same instance must be used for all
    /// chunks from a process so split escape sequences and CRLF pairs are
    /// recognized correctly.
    mutating func sanitize(_ chunk: String) -> String {
        var output = ""

        for scalar in chunk.unicodeScalars {
            if hasPendingCarriageReturn {
                hasPendingCarriageReturn = false
                output.append("\n")
                if scalar.value == CodePoint.lineFeed { continue }
            }

            switch state {
            case .text:
                consumeText(scalar, into: &output)

            case .escape:
                consumeEscapeFollower(scalar, into: &output)

            case .escapeIntermediate:
                consumeEscapeIntermediate(scalar, into: &output)

            case .csi:
                consumeCSI(scalar, into: &output)

            case .controlString:
                consumeControlString(scalar)

            case .controlStringEscape:
                consumeControlStringEscape(scalar)
            }
        }

        return output
    }

    /// Flushes text that cannot be classified until end-of-stream and resets
    /// the sanitizer for optional reuse. Unterminated control sequences are
    /// discarded.
    mutating func finish() -> String {
        let output = hasPendingCarriageReturn ? "\n" : ""
        state = .text
        hasPendingCarriageReturn = false
        return output
    }

    private mutating func consumeText(_ scalar: Unicode.Scalar, into output: inout String) {
        let value = scalar.value

        switch value {
        case CodePoint.carriageReturn:
            // Delay emission so a CRLF split across chunks becomes one newline.
            hasPendingCarriageReturn = true

        case CodePoint.lineFeed:
            output.append("\n")

        case CodePoint.tab:
            output.append("\t")

        case CodePoint.escape:
            state = .escape

        case CodePoint.csi:
            state = .csi

        case CodePoint.dcs, CodePoint.sos, CodePoint.osc, CodePoint.pm, CodePoint.apc:
            state = .controlString

        case CodePoint.nul...0x1F, CodePoint.delete, 0x80...0x9F:
            // Tabs, newlines, CR, and ANSI introducers were handled above.
            // Everything else in C0/C1 (plus DEL) is unsafe plain-text output.
            break

        default:
            output.unicodeScalars.append(scalar)
        }
    }

    private mutating func consumeEscapeFollower(
        _ scalar: Unicode.Scalar,
        into output: inout String
    ) {
        switch scalar.value {
        case 0x5B: // [ — Control Sequence Introducer
            state = .csi

        case 0x50, 0x58, 0x5D, 0x5E, 0x5F: // P, X, ], ^, _
            state = .controlString

        case CodePoint.escape:
            // Consecutive ESC bytes begin a fresh escape sequence.
            state = .escape

        case 0x20...0x2F:
            // ANSI escape intermediates, such as ESC ( B.
            state = .escapeIntermediate

        case 0x30...0x7E:
            // A complete single-character ANSI escape sequence.
            state = .text

        case CodePoint.csi:
            state = .csi

        case CodePoint.dcs, CodePoint.sos, CodePoint.osc, CodePoint.pm, CodePoint.apc:
            state = .controlString

        case CodePoint.stringTerminator:
            state = .text

        case CodePoint.nul...0x1F, CodePoint.delete, 0x80...0x9F:
            // A control interrupts a malformed escape. Preserve only the text
            // controls that the normal plain-text path explicitly allows.
            state = .text
            consumeText(scalar, into: &output)

        default:
            // A non-ANSI Unicode scalar is not part of the escape sequence.
            state = .text
            consumeText(scalar, into: &output)
        }
    }

    private mutating func consumeEscapeIntermediate(
        _ scalar: Unicode.Scalar,
        into output: inout String
    ) {
        switch scalar.value {
        case CodePoint.carriageReturn:
            hasPendingCarriageReturn = true

        case CodePoint.lineFeed:
            output.append("\n")

        case CodePoint.tab:
            output.append("\t")

        case 0x20...0x2F:
            break

        case 0x30...0x7E:
            state = .text

        case CodePoint.escape:
            state = .escape

        case CodePoint.csi:
            state = .csi

        case CodePoint.dcs, CodePoint.sos, CodePoint.osc, CodePoint.pm, CodePoint.apc:
            state = .controlString

        case CodePoint.nul...0x1F, CodePoint.delete, 0x80...0x9F:
            // Ignore embedded controls without retaining them or growing state.
            break

        default:
            state = .text
            consumeText(scalar, into: &output)
        }
    }

    private mutating func consumeCSI(_ scalar: Unicode.Scalar, into output: inout String) {
        switch scalar.value {
        case CodePoint.carriageReturn:
            hasPendingCarriageReturn = true

        case CodePoint.lineFeed:
            output.append("\n")

        case CodePoint.tab:
            output.append("\t")

        case 0x40...0x7E:
            // The ANSI final byte completes the CSI sequence.
            state = .text

        case CodePoint.escape:
            state = .escape

        case CodePoint.csi:
            state = .csi

        case CodePoint.dcs, CodePoint.sos, CodePoint.osc, CodePoint.pm, CodePoint.apc:
            state = .controlString

        case CodePoint.stringTerminator:
            state = .text

        default:
            // Parameter, intermediate, control, and malformed payload bytes are
            // all discarded. No payload is retained between chunks.
            break
        }
    }

    private mutating func consumeControlString(_ scalar: Unicode.Scalar) {
        switch scalar.value {
        case CodePoint.bell, CodePoint.stringTerminator:
            // BEL is the traditional OSC terminator. Accepting it for all ANSI
            // control strings is conservative and prevents malformed output
            // from hiding subsequent process text indefinitely.
            state = .text

        case CodePoint.escape:
            state = .controlStringEscape

        default:
            // Drop payload immediately: OSC 8 links, OSC 52 clipboard content,
            // and arbitrarily large DCS/APC payloads are never buffered.
            break
        }
    }

    private mutating func consumeControlStringEscape(_ scalar: Unicode.Scalar) {
        switch scalar.value {
        case 0x5C, CodePoint.bell, CodePoint.stringTerminator: // \\ or C1 ST
            state = .text

        case CodePoint.escape:
            state = .controlStringEscape

        default:
            // ESC not followed by '\\' belongs to the discarded payload.
            state = .controlString
        }
    }
}
