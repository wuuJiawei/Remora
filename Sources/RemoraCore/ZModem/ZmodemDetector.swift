import Foundation

// MARK: - ZMODEM Stream Detector

/// Result of feeding data through the ZMODEM detector
public struct ZmodemDetectResult: Sendable {
    /// Data that should pass through to the terminal normally
    public let passthrough: Data
    /// If non-nil, a ZMODEM session was detected
    public let trigger: ZmodemTrigger?
    /// Raw ZMODEM data that follows the trigger (includes the full header for engine parsing)
    public let trailingData: Data

    public init(passthrough: Data, trigger: ZmodemTrigger? = nil, trailingData: Data = Data()) {
        self.passthrough = passthrough
        self.trigger = trigger
        self.trailingData = trailingData
    }
}

/// Detects ZMODEM initiation sequences in a terminal output stream.
///
/// The detector looks for the pattern: `**\x18B` followed by `00` (ZRQINIT / sz download)
/// or `01` (ZRINIT / rz upload).
///
/// This is designed to be fed chunks of data as they arrive from the PTY.
/// It maintains a small tail buffer to handle the case where the magic sequence
/// spans two consecutive chunks.
public struct ZmodemDetector: Sendable {
    /// The magic prefix: ** CAN B  (ZPAD ZPAD ZDLE ZHEX)
    private static let magicPrefix: [UInt8] = [
        ZmodemByte.ZPAD,  // '*'  0x2A
        ZmodemByte.ZPAD,  // '*'  0x2A
        ZmodemByte.ZDLE,  // CAN  0x18
        ZmodemHeaderEncoding.ZHEX.rawValue, // 'B'  0x42
    ]

    /// We keep only the last few bytes to detect sequences that span chunk boundaries.
    /// The magic sequence is 6 bytes ("**\x18B00"), so we keep 5 (prefix.count + 1)
    /// to catch a split at any point.
    private var tailBuffer: [UInt8] = []
    private static let tailKeepSize = 5

    public init() {}

    /// Feed a chunk of output data. Returns detection result.
    public mutating func feed(_ data: Data) -> ZmodemDetectResult {
        guard !data.isEmpty else {
            return ZmodemDetectResult(passthrough: data)
        }

        let bytes = Array(data)

        // Combine tail from previous chunk with current data for boundary detection
        let combined = tailBuffer + bytes
        let tailLen = tailBuffer.count

        // Search for magic prefix in combined buffer
        if let matchResult = findMagicSequence(in: combined) {
            let matchOffset = matchResult.offset

            // Calculate how much of the original `data` is "before" the match
            let passthroughFromData: Data
            if matchOffset <= tailLen {
                passthroughFromData = Data()
            } else {
                let dataOffset = matchOffset - tailLen
                passthroughFromData = Data(bytes[0..<dataOffset])
            }

            // Trailing data includes the FULL header (starting from **\x18B...)
            // so the engine can parse it properly
            let trailingData: Data
            if matchOffset < combined.count {
                trailingData = Data(combined[matchOffset...])
            } else {
                trailingData = Data()
            }

            tailBuffer.removeAll()
            return ZmodemDetectResult(
                passthrough: passthroughFromData,
                trigger: matchResult.trigger,
                trailingData: trailingData
            )
        }

        // No match found. Keep only the last few bytes as tail for next call.
        let newTail: [UInt8]
        if bytes.count >= Self.tailKeepSize {
            newTail = Array(bytes.suffix(Self.tailKeepSize))
        } else {
            // Merge old tail + new bytes, keep last tailKeepSize
            let merged = tailBuffer + bytes
            newTail = Array(merged.suffix(Self.tailKeepSize))
        }
        tailBuffer = newTail

        return ZmodemDetectResult(passthrough: data)
    }

    /// Reset detector state (e.g., after a transfer completes)
    public mutating func reset() {
        tailBuffer.removeAll()
    }

    // MARK: - Private

    private struct MagicMatch {
        let offset: Int
        let trigger: ZmodemTrigger
    }

    private func findMagicSequence(in buffer: [UInt8]) -> MagicMatch? {
        let prefix = Self.magicPrefix
        // Need prefix (4 bytes) + 2 hex digits for frame type = 6 bytes minimum
        guard buffer.count >= prefix.count + 2 else { return nil }

        let searchEnd = buffer.count - prefix.count - 2
        for i in 0...searchEnd {
            guard buffer[i] == prefix[0],
                  buffer[i + 1] == prefix[1],
                  buffer[i + 2] == prefix[2],
                  buffer[i + 3] == prefix[3]
            else { continue }

            let h1 = buffer[i + prefix.count]
            let h2 = buffer[i + prefix.count + 1]

            // "30 30" = ASCII '00' = ZRQINIT (sz download)
            if h1 == 0x30, h2 == 0x30 {
                return MagicMatch(offset: i, trigger: .download)
            }
            // "30 31" = ASCII '01' = ZRINIT (rz upload)
            if h1 == 0x30, h2 == 0x31 {
                return MagicMatch(offset: i, trigger: .upload)
            }
        }

        return nil
    }
}
