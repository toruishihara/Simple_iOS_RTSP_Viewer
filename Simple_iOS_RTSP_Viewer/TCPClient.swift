//
//  TCPClient.swift
//  Simple_iOS_RTSP_Viewer
//
//  Created by Toru Ishihara on 2025/12/15.
//

import Foundation
import Network

// MARK: - TCPClient (actor-safe)
actor TCPClient {
    enum TCPError: Error, CustomStringConvertible {
        case notConnected
        case connectFailed(Error?)
        case closed
        case timeout
        case sendFailed(Error)
        case badUTF8
        case badResponse(String)

        var description: String {
            switch self {
            case .notConnected: return "notConnected"
            case .connectFailed(let e): return "connectFailed(\(String(describing: e)))"
            case .closed: return "closed"
            case .timeout: return "timeout"
            case .sendFailed(let e): return "sendFailed(\(e))"
            case .badUTF8: return "badUTF8"
            case .badResponse(let s): return "badResponse(\(s))"
            }
        }
    }

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "TCPClient.queue")

    private var conn: NWConnection?
    private var stateReady = false
    private var buffer = Data()
    private var isClosed = false

    /// Debug
    var enableHexDumpRX = false
    var enableHexDumpTX = false

    init(host: String, port: Int) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(integerLiteral: UInt16(port))
    }

    // MARK: Connect / Close

    func connect(timeoutSeconds: Double = 5.0) async throws {
        if conn != nil, stateReady { return }

        isClosed = false
        buffer.removeAll(keepingCapacity: true)

        let c = NWConnection(host: host, port: port, using: .tcp)
        conn = c

        // Wait for ready state
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false

            c.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                Task { await self.handleStateUpdate(st, cont: cont, resumed: &resumed) }
            }

            c.start(queue: queue)

            // Timeout watchdog
            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                if !resumed {
                    resumed = true
                    cont.resume(throwing: TCPError.timeout)
                }
            }
        }

        // Start RX loop after ready
        receiveLoop()
    }

    private func handleStateUpdate(
        _ st: NWConnection.State,
        cont: CheckedContinuation<Void, Error>,
        resumed: inout Bool
    ) async {
        switch st {
        case .ready:
            stateReady = true
            if !resumed {
                resumed = true
                cont.resume()
            }
        case .failed(let err):
            stateReady = false
            isClosed = true
            if !resumed {
                resumed = true
                cont.resume(throwing: TCPError.connectFailed(err))
            }
        case .cancelled:
            stateReady = false
            isClosed = true
            if !resumed {
                resumed = true
                cont.resume(throwing: TCPError.closed)
            }
        default:
            break
        }
    }

    func close() {
        isClosed = true
        stateReady = false
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        conn = nil
    }

    // MARK: Send

    func send(_ string: String) async throws {
        guard let data = string.data(using: .utf8) else { throw TCPError.badUTF8 }
        try await send(data)
    }

    func send(_ data: Data) async throws {
        guard let c = conn, stateReady, !isClosed else { throw TCPError.notConnected }

        if enableHexDumpTX {
            print("TX \(data.count) bytes:\n\(hexDump(data))")
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: data, completion: .contentProcessed { err in
                if let err {
                    cont.resume(throwing: TCPError.sendFailed(err))
                } else {
                    cont.resume()
                }
            })
        }
    }

    // MARK: Receive Loop (push into actor)

    private func receiveLoop() {
        guard let c = conn else { return }

        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                Task { await self.appendRX(data) }
            }

            if isComplete || error != nil {
                Task { await self.markClosed() }
                return
            }

            self.receiveLoop()
        }
    }

    private func appendRX(_ data: Data) {
        if enableHexDumpRX {
            print("RX \(data.count) bytes:\n\(hexDump(data))")
        }
        buffer.append(data)
    }

    private func markClosed() {
        isClosed = true
        stateReady = false
        conn?.cancel()
        conn = nil
    }

    // MARK: Read helpers

    /// Reads until delimiter appears in the buffered stream. Good for RTSP headers "\r\n\r\n".
    func readUntil(_ delimiter: Data, timeoutSeconds: Double = 5.0) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while true {
            if let range = buffer.range(of: delimiter) {
                let end = range.upperBound
                // IMPORTANT: end must be <= buffer.count (guaranteed because we're inside actor)
                let out = buffer.subdata(in: 0..<end)
                buffer.removeSubrange(0..<end)
                return out
            }

            if isClosed { throw TCPError.closed }
            if Date() > deadline { throw TCPError.timeout }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    /// Reads exactly n bytes from buffered stream (waiting until available).
    func readExact(_ n: Int, timeoutSeconds: Double = 5.0) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while true {
            if buffer.count >= n {
                let out = buffer.subdata(in: 0..<n)
                buffer.removeSubrange(0..<n)
                return out
            }

            if isClosed { throw TCPError.closed }
            if Date() > deadline { throw TCPError.timeout }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: RTSP helpers

    /// Reads RTSP response: headers + (optional) body by Content-Length.
    func readRTSPResponse(timeoutSeconds: Double = 5.0) async throws -> (header: String, body: Data) {
        let headerData = try await readUntil(Data("\r\n\r\n".utf8), timeoutSeconds: timeoutSeconds)
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            throw TCPError.badUTF8
        }

        let contentLength = parseContentLength(headerStr) ?? 0
        if contentLength > 0 {
            let body = try await readExact(contentLength, timeoutSeconds: timeoutSeconds)
            return (headerStr, body)
        } else {
            return (headerStr, Data())
        }
    }

    private func parseContentLength(_ header: String) -> Int? {
        // Case-insensitive "Content-length: 631"
        for line in header.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    return Int(parts[1].trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return nil
    }

    // MARK: Debug

    private func hexDump(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }
            .chunked(16)
            .map { $0.joined(separator: " ") }
            .joined(separator: "\n")
    }
}

// Small helper
private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var out: [[Element]] = []
        out.reserveCapacity((count + size - 1) / size)
        var i = 0
        while i < count {
            out.append(Array(self[i..<Swift.min(i + size, count)]))
            i += size
        }
        return out
    }
}
