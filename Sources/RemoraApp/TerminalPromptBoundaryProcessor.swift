import Foundation

enum TerminalPromptBoundaryToken: Equatable {
    case output(Data)
    case promptStart
}

struct TerminalPromptBoundaryProcessor {
    private static let oscPrefix: [UInt8] = [0x1B, 0x5D]
    private static let promptStartPayload = Array("133;A".utf8)

    private var pendingOSCSequence = Data()

    mutating func process(_ data: Data) -> [TerminalPromptBoundaryToken] {
        var buffer = Data()
        if !pendingOSCSequence.isEmpty {
            buffer.append(pendingOSCSequence)
            pendingOSCSequence.removeAll(keepingCapacity: true)
        }
        buffer.append(data)

        let bytes = Array(buffer)
        var tokens: [TerminalPromptBoundaryToken] = []
        var plainStart = 0
        var index = 0

        while index < bytes.count {
            guard bytes[index] == Self.oscPrefix[0],
                  index + 1 < bytes.count,
                  bytes[index + 1] == Self.oscPrefix[1] else {
                index += 1
                continue
            }

            guard let terminator = Self.findOSCTerminator(in: bytes, after: index + 2) else {
                if plainStart < index {
                    tokens.append(.output(Data(bytes[plainStart..<index])))
                }
                pendingOSCSequence = Data(bytes[index...])
                return Self.coalescing(tokens)
            }

            if plainStart < index {
                tokens.append(.output(Data(bytes[plainStart..<index])))
            }

            let payload = Array(bytes[(index + 2)..<terminator.payloadEnd])
            if payload == Self.promptStartPayload {
                tokens.append(.promptStart)
            } else {
                tokens.append(.output(Data(bytes[index..<terminator.sequenceEnd])))
            }

            index = terminator.sequenceEnd
            plainStart = index
        }

        if plainStart < bytes.count {
            tokens.append(.output(Data(bytes[plainStart..<bytes.count])))
        }

        return Self.coalescing(tokens)
    }

    private static func coalescing(_ tokens: [TerminalPromptBoundaryToken]) -> [TerminalPromptBoundaryToken] {
        var coalesced: [TerminalPromptBoundaryToken] = []

        for token in tokens {
            switch token {
            case .promptStart:
                coalesced.append(.promptStart)
            case .output(let data):
                guard !data.isEmpty else { continue }
                if case .output(let existing)? = coalesced.last {
                    coalesced.removeLast()
                    var merged = existing
                    merged.append(data)
                    coalesced.append(.output(merged))
                } else {
                    coalesced.append(.output(data))
                }
            }
        }

        return coalesced
    }

    private static func findOSCTerminator(in bytes: [UInt8], after start: Int) -> (payloadEnd: Int, sequenceEnd: Int)? {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x07 {
                return (payloadEnd: index, sequenceEnd: index + 1)
            }
            if byte == 0x1B {
                if index + 1 >= bytes.count {
                    return nil
                }
                if bytes[index + 1] == 0x5C {
                    return (payloadEnd: index, sequenceEnd: index + 2)
                }
            }
            index += 1
        }
        return nil
    }
}
