import Foundation

// MARK: - ZMODEM Receive Engine

/// Transfer progress information
public struct ZmodemProgress: Sendable {
    public let fileName: String
    public let fileSize: Int64?
    public let bytesTransferred: Int64
    public let finished: Bool
    public let error: String?

    public init(fileName: String, fileSize: Int64?, bytesTransferred: Int64, finished: Bool = false, error: String? = nil) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.bytesTransferred = bytesTransferred
        self.finished = finished
        self.error = error
    }
}

/// Events emitted by the engine that the host must handle
public enum ZmodemEvent: Sendable {
    /// Engine needs to send data back to the remote (protocol responses)
    case sendToRemote(Data)
    /// A file is being offered; host should provide a file URL to save to
    case fileOffered(name: String, size: Int64?)
    /// Progress update
    case progress(ZmodemProgress)
    /// Transfer session finished (all files done or aborted)
    case sessionFinished
    /// An error occurred
    case error(String)
}

/// ZMODEM receive state machine.
///
/// Usage:
/// 1. Create engine, provide event handler
/// 2. Feed initial trailing data from detector
/// 3. Feed all subsequent PTY output data
/// 4. When `fileOffered` event fires, call `acceptFile(saveTo:)` or `skipFile()`
/// 5. Engine emits `sendToRemote` events — write that data to the PTY
public final class ZmodemReceiveEngine: @unchecked Sendable {
    public typealias EventHandler = @Sendable (ZmodemEvent) -> Void

    private enum State {
        case waitingForZRQINIT
        case waitingForZFILE
        case waitingForFileAccept
        case receivingData
        case waitingForZFIN
        case finished
    }

    private var state: State = .waitingForZRQINIT
    private var buffer = Data()
    private var useCRC32 = true
    private var insideDataFrame = false
    private let onEvent: EventHandler

    // Current file state
    private var currentFileName: String = ""
    private var currentFileSize: Int64?
    private var currentFileHandle: FileHandle?
    private var currentFileURL: URL?
    private var bytesReceived: Int64 = 0

    public var isActive: Bool {
        state != .finished
    }

    public init(onEvent: @escaping EventHandler) {
        self.onEvent = onEvent
    }

    /// Feed raw PTY output data into the engine
    public func feedOutput(_ data: Data) {
        guard isActive else { return }
        buffer.append(data)

        // Safety: prevent unbounded buffer growth
        if buffer.count > 4 * 1024 * 1024 {
            emit(.error("ZMODEM buffer overflow"))
            cancel()
            return
        }

        processBuffer()
    }

    /// Accept the offered file, saving to the given URL
    public func acceptFile(saveTo url: URL) {
        guard state == .waitingForFileAccept else { return }
        currentFileURL = url
        bytesReceived = 0

        // Create/truncate the file
        FileManager.default.createFile(atPath: url.path, contents: nil)
        currentFileHandle = FileHandle(forWritingAtPath: url.path)

        state = .receivingData

        // Send ZRPOS at offset 0 to start receiving
        let rpos = ZmodemHeader.withPosition(type: .ZRPOS, 0)
        emit(.sendToRemote(zmodemEncodeHexHeader(rpos)))

        // Process any buffered data
        processBuffer()
    }

    /// Skip the offered file
    public func skipFile() {
        guard state == .waitingForFileAccept else { return }
        state = .waitingForZFILE

        let skip = ZmodemHeader(type: .ZSKIP)
        emit(.sendToRemote(zmodemEncodeHexHeader(skip)))
    }

    /// Cancel the entire transfer
    public func cancel() {
        closeCurrentFile()
        // Standard ZMODEM abort: 8x CAN + 8x BS
        var abort: [UInt8] = []
        for _ in 0..<8 { abort.append(ZmodemByte.ZDLE) } // CAN = 0x18
        for _ in 0..<8 { abort.append(0x08) }            // BS
        emit(.sendToRemote(Data(abort)))
        state = .finished
        emit(.sessionFinished)
    }

    // MARK: - State Machine

    private func processBuffer() {
        // Prevent re-entrancy
        var iterations = 0
        let maxIterations = 500

        while !buffer.isEmpty, isActive, iterations < maxIterations {
            iterations += 1
            let consumed: Bool

            switch state {
            case .waitingForZRQINIT:
                consumed = handleWaitingForZRQINIT()
            case .waitingForZFILE:
                consumed = handleWaitingForZFILE()
            case .waitingForFileAccept:
                consumed = false // Waiting for host to call acceptFile/skipFile
            case .receivingData:
                consumed = handleReceivingData()
            case .waitingForZFIN:
                consumed = handleWaitingForZFIN()
            case .finished:
                consumed = false
            }

            if !consumed { break }
        }
    }

    private func handleWaitingForZRQINIT() -> Bool {
        guard let (header, consumed) = parseNextHeader() else { return false }
        buffer.removeFirst(consumed)

        if header.type == .ZRQINIT {
            // Respond with ZRINIT
            state = .waitingForZFILE
            let flags = ZmodemRInitFlags([.canFC32, .canFDX, .canOVIO])
            let rinit = ZmodemHeader(type: .ZRINIT, p0: flags.rawValue)
            emit(.sendToRemote(zmodemEncodeHexHeader(rinit)))
            return true
        }

        // Unexpected header, try to continue
        return true
    }

    private func handleWaitingForZFILE() -> Bool {
        guard let (header, consumed) = parseNextHeader() else { return false }

        if header.type == .ZFIN {
            buffer.removeFirst(consumed)
            // Session done, respond with ZFIN
            let fin = ZmodemHeader(type: .ZFIN)
            emit(.sendToRemote(zmodemEncodeHexHeader(fin)))
            state = .finished
            emit(.sessionFinished)
            return true
        }

        if header.type == .ZFILE {
            buffer.removeFirst(consumed)
            // Parse the sub-packet containing filename and size
            guard let (fileInfo, subType, subConsumed) = parseNextSubPacket() else {
                // Need more data — put header info aside, wait for sub-packet
                return false
            }
            buffer.removeFirst(subConsumed)
            _ = subType

            parseFileInfo(fileInfo)
            state = .waitingForFileAccept
            emit(.fileOffered(name: currentFileName, size: currentFileSize))
            return true
        }

        if header.type == .ZSINIT {
            buffer.removeFirst(consumed)
            // Skip ZSINIT sub-packet data
            if let (_, _, subConsumed) = parseNextSubPacket() {
                buffer.removeFirst(subConsumed)
            }
            // ACK it
            let ack = ZmodemHeader(type: .ZACK)
            emit(.sendToRemote(zmodemEncodeHexHeader(ack)))
            return true
        }

        // Skip unknown headers
        buffer.removeFirst(consumed)
        return true
    }

    private func handleReceivingData() -> Bool {
        // If we're inside a ZDATA frame, consume sub-packets first
        if insideDataFrame {
            let consumed = consumeDataSubPackets()
            if !consumed, !insideDataFrame {
                // Frame ended (ZCRCE/ZCRCW), try parsing next header
                return handleReceivingData()
            }
            return consumed
        }

        guard let (header, consumed) = parseNextHeader() else { return false }

        if header.type == .ZDATA {
            buffer.removeFirst(consumed)
            insideDataFrame = true
            return consumeDataSubPackets()
        }

        if header.type == .ZEOF {
            buffer.removeFirst(consumed)
            finishCurrentFile()
            state = .waitingForZFILE

            let flags = ZmodemRInitFlags([.canFC32, .canFDX, .canOVIO])
            let rinit = ZmodemHeader(type: .ZRINIT, p0: flags.rawValue)
            emit(.sendToRemote(zmodemEncodeHexHeader(rinit)))
            return true
        }

        if header.type == .ZFIN {
            buffer.removeFirst(consumed)
            finishCurrentFile()
            let fin = ZmodemHeader(type: .ZFIN)
            emit(.sendToRemote(zmodemEncodeHexHeader(fin)))
            state = .finished
            emit(.sessionFinished)
            return true
        }

        // Unexpected header during data receive
        buffer.removeFirst(consumed)
        return true
    }

    private func handleWaitingForZFIN() -> Bool {
        guard let (header, consumed) = parseNextHeader() else { return false }
        buffer.removeFirst(consumed)

        if header.type == .ZFIN {
            let fin = ZmodemHeader(type: .ZFIN)
            emit(.sendToRemote(zmodemEncodeHexHeader(fin)))
            state = .finished
            emit(.sessionFinished)
        }
        return true
    }

    // MARK: - Data Sub-packet Processing

    private func consumeDataSubPackets() -> Bool {
        var didConsume = false

        while !buffer.isEmpty {
            guard let (payload, subType, consumed) = parseNextSubPacket() else {
                break
            }
            buffer.removeFirst(consumed)
            didConsume = true

            // Write payload to file
            writeToFile(payload)

            switch subType {
            case .ZCRCG:
                // More data coming, continue
                continue
            case .ZCRCQ:
                // Sender wants ACK, send ZACK with current position
                let ack = ZmodemHeader.withPosition(type: .ZACK, UInt32(bytesReceived))
                emit(.sendToRemote(zmodemEncodeHexHeader(ack)))
                continue
            case .ZCRCE:
                // End of frame, header follows
                insideDataFrame = false
                return true
            case .ZCRCW:
                // End of frame, sender waits for ACK
                insideDataFrame = false
                let ack = ZmodemHeader.withPosition(type: .ZACK, UInt32(bytesReceived))
                emit(.sendToRemote(zmodemEncodeHexHeader(ack)))
                return true
            }
        }

        return didConsume
    }

    // MARK: - Header Parsing

    private func parseNextHeader() -> (ZmodemHeader, Int)? {
        let bytes = Array(buffer)
        let slice = bytes[...]

        // Look for ZPAD or ZDLE that starts a header
        for i in slice.indices {
            // Hex header: ZPAD ZPAD ZDLE ZHEX
            if i + 3 < slice.endIndex,
               slice[i] == ZmodemByte.ZPAD,
               slice[i + 1] == ZmodemByte.ZPAD,
               slice[i + 2] == ZmodemByte.ZDLE,
               slice[i + 3] == ZmodemHeaderEncoding.ZHEX.rawValue
            {
                let headerStart = i + 4
                guard headerStart < slice.endIndex else { return nil }
                if let (header, hConsumed) = zmodemParseHexHeader(slice[headerStart...]) {
                    return (header, headerStart + hConsumed - slice.startIndex)
                }
                return nil // Incomplete
            }

            // Binary header CRC-32: ZPAD ZDLE ZBIN32
            if i + 2 < slice.endIndex,
               slice[i] == ZmodemByte.ZPAD,
               slice[i + 1] == ZmodemByte.ZDLE,
               slice[i + 2] == ZmodemHeaderEncoding.ZBIN32.rawValue
            {
                let headerStart = i + 3
                guard headerStart < slice.endIndex else { return nil }
                if let (header, hConsumed) = zmodemParseBin32Header(slice[headerStart...]) {
                    useCRC32 = true
                    return (header, headerStart + hConsumed - slice.startIndex)
                }
                return nil
            }

            // Binary header CRC-16: ZPAD ZDLE ZBIN
            if i + 2 < slice.endIndex,
               slice[i] == ZmodemByte.ZPAD,
               slice[i + 1] == ZmodemByte.ZDLE,
               slice[i + 2] == ZmodemHeaderEncoding.ZBIN.rawValue
            {
                let headerStart = i + 3
                guard headerStart < slice.endIndex else { return nil }
                if let (header, hConsumed) = zmodemParseBinHeader(slice[headerStart...]) {
                    useCRC32 = false
                    return (header, headerStart + hConsumed - slice.startIndex)
                }
                return nil
            }
        }

        return nil
    }

    private func parseNextSubPacket() -> (Data, ZmodemSubPacketType, Int)? {
        let bytes = Array(buffer)
        let slice = bytes[...]
        if useCRC32 {
            return zmodemParseSubPacket32(slice)
        } else {
            return zmodemParseSubPacket16(slice)
        }
    }

    // MARK: - File I/O

    private func parseFileInfo(_ data: Data) {
        // ZMODEM file info format: "filename\0size modification_date ..."
        // The filename is null-terminated, followed by optional space-separated metadata
        let bytes = Array(data)
        let nullIndex = bytes.firstIndex(of: 0) ?? bytes.endIndex
        currentFileName = String(bytes: bytes[0..<nullIndex], encoding: .utf8) ?? "unknown"

        // Parse size from metadata after null
        currentFileSize = nil
        if nullIndex + 1 < bytes.count {
            let metaStart = nullIndex + 1
            let metaBytes = bytes[metaStart...]
            if let metaStr = String(bytes: metaBytes, encoding: .utf8) {
                let parts = metaStr.split(separator: " ")
                if let first = parts.first, let size = Int64(first) {
                    currentFileSize = size
                }
            }
        }
    }

    private func writeToFile(_ data: Data) {
        guard !data.isEmpty else { return }
        currentFileHandle?.write(data)
        bytesReceived += Int64(data.count)
        emit(.progress(ZmodemProgress(
            fileName: currentFileName,
            fileSize: currentFileSize,
            bytesTransferred: bytesReceived
        )))
    }

    private func finishCurrentFile() {
        closeCurrentFile()
        emit(.progress(ZmodemProgress(
            fileName: currentFileName,
            fileSize: currentFileSize,
            bytesTransferred: bytesReceived,
            finished: true
        )))
    }

    private func closeCurrentFile() {
        try? currentFileHandle?.close()
        currentFileHandle = nil
    }

    private func emit(_ event: ZmodemEvent) {
        onEvent(event)
    }
}
