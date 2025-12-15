//
//  TCPClient.swift
//  Simple_iOS_RTSP_Viewer
//
//  Created by Toru Ishihara on 2025/12/15.
//

import Foundation
import Network

final class TCPClient {
    enum TCPError: Error {
        case notConnected
        case connectFailed
        case connectionClosed
        case timeout
        case invalidUTF8
    }

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "TCPClient.queue")

    private var conn: NWConnection?
    private var buffer = Data()

    init(host: String, port: Int) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(integerLiteral: UInt16(port))
    }

    func connect(timeoutSeconds: Double = 5.0) async throws {
        let params = NWParameters.tcp
        let c = NWConnection(host: host, port: port, using: params)
        self.conn = c

        try await withCheckedThrowingContinuation { cont in
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume()
                case .failed:
                    cont.resume(throwing: TCPError.connectFailed)
                default:
                    break
                }
            }
            c.start(queue: self.queue)
        }

        // Start a continuous receive loop (fills `buffer`)
        receiveLoop()
    }

    func close() {
        conn?.cancel()
        conn = nil
        buffer.removeAll(keepingCapacity: false)
    }

    func send(_ string: String) async throws {
        guard let data = string.data(using: .utf8) else { throw TCPError.invalidUTF8 }
        try await send(data)
    }

    func send(_ data: Data) async throws {
        guard let c = conn else { throw TCPError.notConnected }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: data, completion: .contentProcessed { err in
                if let err {
                    cont.resume(throwing: err)
                } else {
                    cont.resume(returning: ())
                }
            })
        }
    }

    /// Reads until delimiter appears in the buffered stream. Great for RTSP header: "\r\n\r\n".
    func readUntil(_ delimiter: Data, timeoutSeconds: Double = 5.0) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while true {
            if let range = buffer.range(of: delimiter) {
                let end = range.upperBound
                let out = buffer.subdata(in: 0..<end)
                buffer.removeSubrange(0..<end)
                return out
            }

            if Date() > deadline { throw TCPError.timeout }
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
    }

    /// Reads exactly N bytes from the buffered stream.
    func readExactly(_ count: Int, timeoutSeconds: Double = 5.0) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while buffer.count < count {
            if Date() > deadline { throw TCPError.timeout }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return out
    }
    
    // MARK: - Internal receive loop

    private func receiveLoop() {
        guard let c = conn else { return }

        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
            }

            if isComplete || error != nil {
                // TCP closed
                self.close()
                return
            }

            self.receiveLoop()
        }
    }
}
