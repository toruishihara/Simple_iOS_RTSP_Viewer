//
//  RTPH264Receiver.swift
//  H.264 FU-A Receiver
//
//  Created by Toru Ishihara on 2025/12/16.
//

import Foundation
import Network

final class RTPH264Receiver {
    enum RTPError: Error { case bindFailed, badPacket }

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "rtp.h264.receiver")

    // Reassembly state for one FU-A NAL
    private var fuBuffer = Data()
    private var fuActive = false

    // Access unit grouping (same RTP timestamp)
    private var currentTimestamp: UInt32?

    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start(onNAL: @escaping (Data, UInt32) -> Void) throws {
        let params = NWParameters.udp
        let listener = try NWListener(using: params, on: port)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.receiveLoop(conn: conn, onNAL: onNAL)
        }

        listener.stateUpdateHandler = { state in
            if case .failed(let e) = state {
                print("RTP listener failed:", e)
            }
        }

        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - UDP receive loop

    private func receiveLoop(conn: NWConnection, onNAL: @escaping (Data, UInt32) -> Void) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            //print("RTPH264 loop \(data?.count ?? 0)")
            //print(data?.hexDump() ?? "empty")
            if let data, !data.isEmpty {
                self.handleRTPPacket(data, onNAL: onNAL)
            }
            if error == nil {
                self.receiveLoop(conn: conn, onNAL: onNAL)
            }
        }
    }

    // MARK: - RTP + H264 (FU-A only)
    private var s_cnt: Int = 0

    private func handleRTPPacket(_ pkt: Data, onNAL: (Data, UInt32) -> Void) {
        // RTP header: min 12 bytes
        guard pkt.count >= 12 else { return }

        let b0 = pkt[0]
        let version = b0 >> 6
        guard version == 2 else { return }

        let hasPadding = (b0 & 0x20) != 0
        let hasExt = (b0 & 0x10) != 0
        let csrcCount = Int(b0 & 0x0F)

        let b1 = pkt[1]
        let marker = (b1 & 0x80) != 0
        let payloadType = b1 & 0x7F
        _ = marker
        _ = payloadType // likely 96 for H264 dynamic

        var offset = 12 + (4 * csrcCount)
        guard pkt.count >= offset else { return }

        //print("b0=" + String(format: "%02X", b0) + " b1=" + String(format: "%02X", b1))
        // RTP extension header (if present)
        //print("hasExt=\(hasExt)") false
        //print("marker=\(marker)")
        //print("payloadType=\(payloadType)") 96
        if hasExt {
            guard pkt.count >= offset + 4 else { return }
            // 16-bit profile, 16-bit length (in 32-bit words)
            let extLenWords = (UInt16(pkt[offset+2]) << 8) | UInt16(pkt[offset+3])
            offset += 4 + Int(extLenWords) * 4
            guard pkt.count >= offset else { return }
        }

        // Padding (if present) – last byte indicates pad length
        var end = pkt.count
        //print("hasPadding=\(hasPadding)") false
        if hasPadding {
            let padLen = Int(pkt[pkt.count - 1])
            if padLen > 0 && padLen <= end { end -= padLen }
        }

        // Timestamp at bytes 4..7
        let ts = (UInt32(pkt[4]) << 24) | (UInt32(pkt[5]) << 16) | (UInt32(pkt[6]) << 8) | UInt32(pkt[7])
        //print("ts=\(ts)")

        // Flush access unit boundary on timestamp change (simple heuristic)
        if let cur = currentTimestamp, cur != ts {
            // If a FU was in progress and never ended, drop it
            fuBuffer.removeAll(keepingCapacity: true)
            print("fuActive=false")
            fuActive = false
        }
        currentTimestamp = ts

        //print("end=\(end) offset=\(offset)") v 12
        guard end > offset else { return }
        let payload = pkt.subdata(in: offset..<end)

        // H264 FU-A expected: first byte NAL header with type 28
        guard payload.count >= 2 else { return }
        if (s_cnt < 32) {
            print("RTP payload size=\(payload.count)")
            print(payload.hexDump())
            s_cnt = s_cnt + 1
        }
        let nal0 = payload[0]
        let nalType = nal0 & 0x1F
        // NALU type (5=IDR, 7=SPS, 8=PPS, ...)
        print(String(format: "payload[0]=%02X nalType=%02X", nal0, nalType))
        guard nalType == 28 else {
            // Not FU-A (could be STAP-A or single NAL). If you want, handle later.
            
            if (nalType == 1) {
                print("P-frame")
                fuBuffer.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                fuBuffer.append(payload)
                fuActive = false
                // Convert to AVCC here, [ 4-byte big-endian length ][ NALU payload ]
                var naluData = fuBuffer
                writeLengthPrefix(&naluData)
                
                onNAL(naluData, ts)
                fuBuffer.removeAll(keepingCapacity: true)
            } else if (nalType == 7){
                print("SPS")
            } else if (nalType == 8){
                print("PPS")
            } else {
                print("Not FU-A or Single NAL nalType=\(nalType)")
            }
            return
        }
        print("IDR with FU-A")
        // 2 byte header is FU-A
        let fuHeader = payload[1]
        let startFlag = (fuHeader & 0x80) != 0
        let endFlag = (fuHeader & 0x40) != 0
        let originalType = fuHeader & 0x1F

        let f = nal0 & 0x80
        let nri = nal0 & 0x60
        let reconstructedNALHeader = f | nri | originalType
        print(String(format: "fuHeader=%02X reconstructedNALHeader=%02X", fuHeader, reconstructedNALHeader))

        let fragmentData = payload.dropFirst(2) // actual fragment bytes

        if startFlag {
            // Start: write Annex-B start code + reconstructed header + fragment
            fuBuffer.removeAll(keepingCapacity: true)
            fuActive = true
            fuBuffer.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            fuBuffer.append(reconstructedNALHeader)
            fuBuffer.append(fragmentData)
        } else if fuActive {
            // Middle/end: append fragment bytes
            fuBuffer.append(fragmentData)
        } else {
            // Got middle without start; drop
            return
        }

        if endFlag == true && fuActive == true {
            fuActive = false
            // Convert to AVCC here, [ 4-byte big-endian length ][ NALU payload ]
            var naluData = fuBuffer
            writeLengthPrefix(&naluData)
            
            onNAL(naluData, ts)
            fuBuffer.removeAll(keepingCapacity: true)
        }
    }
    
    func writeLengthPrefix(_ data: inout Data) {
        let payloadLength = data.count - 4
        var beLen = UInt32(payloadLength).bigEndian
        print("data.count=\(data.count) payloadLength=\(payloadLength)")
        
        withUnsafeBytes(of: &beLen) { lenBytes in
            data.replaceSubrange(0..<4, with: lenBytes)
        }
    }
}
