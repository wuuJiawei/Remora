import Foundation

// MARK: - ZMODEM Send Engine

/// ZMODEM send state machine for uploading files (rz on remote).
///
/// Protocol flow (sender perspective):
/// 1. Remote rz sends ZRINIT → we detect it via ZmodemDetector
/// 2. Host calls setFiles() after user picks files
/// 3. We send ZFILE header + filename sub-packet
/// 4. Remote responds with ZRPOS (offset to start from)
/// 5. We send ZDATA header + data sub-packets
/// 6. We send ZEOF header
/// 7. Remote sends ZRINIT (ready for next file) or we send ZFIN
/// 8. Remote responds with ZFIN, we send "OO" to finish
public final class ZmodemSendEngine: @unchecked Sendable {
    public typealias EventHandler = @Sendable (ZmodemEvent) -> Void

    private enum State {
        case waitingForFiles    // Buffering data until host calls setFiles
        case waitingForZRINIT   // Files set, waiting for ZRINIT to start sending
        case waitingForZRPOS
        case sendingData
        case waitingForZRINITAfterEOF
        case waitingForFinalZFIN
        case finished
    }

    private var state: State = .waitingForFiles
    private var buffer = Data()
    private let onEvent: EventHandler

    // File queue
    private var fileQueue: [(url: URL, name: String, size: Int64)] = []
    private var currentFileData: Data?
    private var currentFileName: String = ""
    private var currentFileSize: Int64 = 0
    private var bytesSent: Int64 = 0
    private var znakRetryCount = 0
    private let maxZnakRetries = 5

    private let subPacketSize = 1024

    // Debug logging
    private static func log(_ message: String) {
        #if DEBUG
        NSLog("[ZmodemSend] %@", message)
        #endif
    }

    public var isActive: Bool {
        state != .finished
    }

    public init(onEvent: @escaping EventHandler) {
        self.onEvent = onEvent
    }

    /// Set the files to upload. Transitions from waitingForFiles → waitingForZRINIT
    /// and processes any buffered data.
    public func setFiles(_ urls: [URL]) {
        fileQueue = urls.compactMap { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else { return nil }
            return (url: url, name: url.lastPathComponent, size: size)
        }
        guard !fileQueue.isEmpty else {
            cancel()
            return
        }
        if state == .waitingForFiles {
            state = .waitingForZRINIT
            Self.log("setFiles: \(fileQueue.count) files, buffer has \(buffer.count) bytes")
            processBuffer()
        }
    }

    /// Feed raw PTY output data (remote responses) into the engine
    public func feedOutput(_ data: Data) {
        guard isActive else { return }
        buffer.append(data)
        Self.log("feedOutput: +\(data.count) bytes, total buffer=\(buffer.count), state=\(state)")

        if buffer.count > 4 * 1024 * 1024 {
            emit(.error("ZMODEM send buffer overflow"))
            cancel()
            return
        }

        // Don't process until files are set
        guard state != .waitingForFiles else { return }
        processBuffer()
    }

    /// Cancel the transfer
    public func cancel() {
        guard state != .finished else { return }
        var abort: [UInt8] = []
        for _ in 0..<8 { abort.append(ZmodemByte.ZDLE) }
        for _ in 0..<8 { abort.append(0x08) }
        emit(.sendToRemote(Data(abort)))
        state = .finished
        emit(.sessionFinished)
    }

    // MARK: - State Machine

    private func processBuffer() {
        var iterations = 0
        let maxIterations = 200

        while !buffer.isEmpty, isActive, state != .waitingForFiles, iterations < maxIterations {
            iterations += 1
            let consumed: Bool

            switch state {
            case .waitingForFiles:
                consumed = false
            case .waitingForZRINIT:
                consumed = handleWaitingForZRINIT()
            case .waitingForZRPOS:
                consumed = handleWaitingForZRPOS()
            case .sendingData:
                consumed = false
            case .waitingForZRINITAfterEOF:
                consumed = handleWaitingForZRINITAfterEOF()
            case .waitingForFinalZFIN:
                consumed = handleWaitingForFinalZFIN()
            case .finished:
                consumed = false
            }

            if !consumed { break }
        }
    }

    private func handleWaitingForZRINIT() -> Bool {
        guard let (header, consumed) = parseNextHeader() else {
            Self.log("waitingForZRINIT: no header found in \(buffer.count) bytes")
            if buffer.count > 0 {
                let preview = Array(buffer.prefix(min(buffer.count, 64)))
                Self.log("  buffer hex: \(preview.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }
            return false
        }
        buffer.removeFirst(consumed)
        Self.log("waitingForZRINIT: got header type=\(header.type) consumed=\(consumed)")

        if header.type == .ZRINIT {
            sendNextFile()
            return true
        }
        return true
    }

    private func handleWaitingForZRPOS() -> Bool {
        guard let (header, consumed) = parseNextHeader() else {
            Self.log("waitingForZRPOS: no header found in \(buffer.count) bytes")
            return false
        }
        buffer.removeFirst(consumed)
        Self.log("waitingForZRPOS: got header type=\(header.type)")

        if header.type == .ZRPOS {
            let offset = header.position
            bytesSent = Int64(offset)
            state = .sendingData
            sendFileData(from: offset)
            return true
        }
        if header.type == .ZSKIP {
            sendNextFile()
            return true
        }
        if header.type == .ZABORT {
            state = .finished
            emit(.sessionFinished)
            return true
        }
        if header.type == .ZRINIT {
            // rz resends ZRINIT before it processes our ZFILE — just ignore it
            Self.log("waitingForZRPOS: ignoring stale ZRINIT")
            return true
        }
        if header.type == .ZNAK {
            // rz couldn't parse our last packet — resend ZFILE
            znakRetryCount += 1
            Self.log("waitingForZRPOS: got ZNAK #\(znakRetryCount), resending ZFILE")
            if znakRetryCount > maxZnakRetries {
                Self.log("waitingForZRPOS: too many ZNAKs, aborting")
                emit(.error("Transfer failed: too many retries"))
                cancel()
                return true
            }
            resendCurrentZFILE()
            return true
        }
        return true
    }

    private func handleWaitingForZRINITAfterEOF() -> Bool {
        guard let (header, consumed) = parseNextHeader() else { return false }
        buffer.removeFirst(consumed)

        if header.type == .ZRINIT {
            sendNextFile()
            return true
        }
        if header.type == .ZACK {
            return true
        }
        return true
    }

    private func handleWaitingForFinalZFIN() -> Bool {
        guard let (header, consumed) = parseNextHeader() else { return false }
        buffer.removeFirst(consumed)

        if header.type == .ZFIN {
            emit(.sendToRemote(Data([0x4F, 0x4F]))) // "OO"
            state = .finished
            emit(.sessionFinished)
            return true
        }
        return true
    }

    // MARK: - File Sending

    private func sendNextFile() {
        guard !fileQueue.isEmpty else {
            let fin = ZmodemHeader(type: .ZFIN)
            emit(.sendToRemote(zmodemEncodeHexHeader(fin)))
            state = .waitingForFinalZFIN
            return
        }

        let file = fileQueue.removeFirst()
        currentFileName = file.name
        currentFileSize = file.size
        bytesSent = 0
        znakRetryCount = 0

        guard let data = try? Data(contentsOf: file.url) else {
            emit(.error("Failed to read file: \(file.name)"))
            sendNextFile()
            return
        }
        currentFileData = data
        sendZFILE()
    }

    private func sendZFILE() {
        Self.log("sendZFILE: sending ZFILE for '\(currentFileName)' size=\(currentFileSize)")

        // Use ZBIN32 header + CRC-32 sub-packet (must be consistent)
        let zfile = ZmodemHeader(type: .ZFILE)
        let headerData = zmodemEncodeBin32Header(zfile)

        // Sub-packet: "name\0size modtime filemode serialnumber filesremaining bytesremaining\0"
        var info: [UInt8] = Array(currentFileName.utf8)
        info.append(0)
        let meta = "\(currentFileSize) 0 0 0 1 \(currentFileSize)"
        info.append(contentsOf: Array(meta.utf8))
        info.append(0)
        let subPacketData = zmodemEncodeSubPacket32(Data(info), type: .ZCRCW)

        // Send header + sub-packet as a single write to avoid fragmentation
        var combined = headerData
        combined.append(subPacketData)
        Self.log("sendZFILE: total \(combined.count) bytes, header=\(headerData.count) sub=\(subPacketData.count)")
        let preview = Array(combined.prefix(min(combined.count, 80)))
        Self.log("sendZFILE hex: \(preview.map { String(format: "%02X", $0) }.joined(separator: " "))")
        emit(.sendToRemote(combined))

        state = .waitingForZRPOS
        emit(.progress(ZmodemProgress(fileName: currentFileName, fileSize: currentFileSize, bytesTransferred: 0)))
    }

    private func resendCurrentZFILE() {
        guard currentFileData != nil else { return }
        sendZFILE()
    }

    private func sendFileData(from offset: UInt32) {
        guard let fileData = currentFileData else { return }
        Self.log("sendFileData: from offset=\(offset), total=\(fileData.count)")

        // Build entire ZDATA frame as one contiguous buffer to avoid fragmentation
        var frame = Data()

        // ZDATA header — use ZBIN32 to match CRC-32 sub-packets
        let zdata = ZmodemHeader.withPosition(type: .ZDATA, offset)
        frame.append(zmodemEncodeBin32Header(zdata))

        var pos = Int(offset)
        let total = fileData.count

        while pos < total {
            let end = min(pos + subPacketSize, total)
            let chunk = fileData[pos..<end]
            let isLast = end >= total

            let subType: ZmodemSubPacketType = isLast ? .ZCRCE : .ZCRCG
            frame.append(zmodemEncodeSubPacket32(Data(chunk), type: subType))

            pos = end
            bytesSent = Int64(pos)
        }

        // Send entire frame as one write
        emit(.sendToRemote(frame))

        emit(.progress(ZmodemProgress(
            fileName: currentFileName,
            fileSize: currentFileSize,
            bytesTransferred: bytesSent
        )))

        // Send ZEOF
        let zeof = ZmodemHeader.withPosition(type: .ZEOF, UInt32(total))
        emit(.sendToRemote(zmodemEncodeHexHeader(zeof)))

        state = .waitingForZRINITAfterEOF
        emit(.progress(ZmodemProgress(
            fileName: currentFileName,
            fileSize: currentFileSize,
            bytesTransferred: bytesSent,
            finished: true
        )))
        currentFileData = nil
    }

    // MARK: - Header Parsing

    private func parseNextHeader() -> (ZmodemHeader, Int)? {
        let bytes = Array(buffer)
        let slice = bytes[...]

        for i in slice.indices {
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
                return nil
            }

            if i + 2 < slice.endIndex,
               slice[i] == ZmodemByte.ZPAD,
               slice[i + 1] == ZmodemByte.ZDLE,
               slice[i + 2] == ZmodemHeaderEncoding.ZBIN32.rawValue
            {
                let headerStart = i + 3
                guard headerStart < slice.endIndex else { return nil }
                if let (header, hConsumed) = zmodemParseBin32Header(slice[headerStart...]) {
                    return (header, headerStart + hConsumed - slice.startIndex)
                }
                return nil
            }

            if i + 2 < slice.endIndex,
               slice[i] == ZmodemByte.ZPAD,
               slice[i + 1] == ZmodemByte.ZDLE,
               slice[i + 2] == ZmodemHeaderEncoding.ZBIN.rawValue
            {
                let headerStart = i + 3
                guard headerStart < slice.endIndex else { return nil }
                if let (header, hConsumed) = zmodemParseBinHeader(slice[headerStart...]) {
                    return (header, headerStart + hConsumed - slice.startIndex)
                }
                return nil
            }
        }

        return nil
    }

    private func emit(_ event: ZmodemEvent) {
        onEvent(event)
    }
}
