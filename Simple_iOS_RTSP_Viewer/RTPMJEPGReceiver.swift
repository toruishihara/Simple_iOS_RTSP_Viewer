//
//  RTPMJEPGReceiver.swift
//  Simple_iOS_RTSP_Viewer
//
//  Created by Toru Ishihara on 2025/12/23.
//

//
//  RTPH264Receiver.swift
//  H.264 FU-A Receiver
//
//  Created by Toru Ishihara on 2025/12/16.
//

import Foundation
import Network

struct RFC2435Header {
    let typeSpecific: UInt8
    let fragmentOffset: Int // 3 bytes
    let type: UInt8
    let q: UInt8
    let width: Int
    let height: Int
}

final class RTPMJPEGReceiver {
    var onJPEGFrame: ((Data, UInt32) -> Void)?
    enum RTPError: Error { case bindFailed, badPacket }
    
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "rtp.mjpeg.receiver")
    
    // Frame info
    private var currentTimestamp: UInt32?
    private var frameBuffer = Data()
    private var expectedSizeHint: Int = 0
    private var width: Int = 0
    private var height: Int = 0
    private var qTables = Data()
    
    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }
    
    func start() throws {
        let params = NWParameters.udp
        let listener = try NWListener(using: params, on: port)
        self.listener = listener
        
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.receiveLoop(conn: conn, onJPEGFrame: onJPEGFrame!)
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
    
    private func receiveLoop(conn: NWConnection, onJPEGFrame: @escaping (Data, UInt32) -> Void) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            //print("RTPH264 loop \(data?.count ?? 0)")
            //print(data?.hexDump() ?? "empty")
            if let data, !data.isEmpty {
                self.handleRTPPacket(data, onJPEGFrame: onJPEGFrame)
            }
            if error == nil {
                self.receiveLoop(conn: conn, onJPEGFrame: onJPEGFrame)
            }
        }
    }
    
    private var s_cnt: Int = 0
    
    // MARK: - RTP + RFC2435 JPEG
    private func handleRTPPacket(_ pkt: Data, onJPEGFrame: (Data, UInt32) -> Void) {
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
        _ = payloadType // likely 26 for MJPEG
        
        var offset = 12 + (4 * csrcCount)
        guard pkt.count >= offset else { return }
        
        if hasExt {
            guard pkt.count >= offset + 4 else { return }
            // 16-bit profile, 16-bit length (in 32-bit words)
            let extLenWords = (UInt16(pkt[offset+2]) << 8) | UInt16(pkt[offset+3])
            offset += 4 + Int(extLenWords) * 4
            guard pkt.count >= offset else { return }
        }
        
        // Padding (if present) – last byte indicates pad length
        var end = pkt.count
        if hasPadding {
            let padLen = Int(pkt[pkt.count - 1])
            if padLen > 0 && padLen <= end { end -= padLen }
        }
        
        // Timestamp at bytes 4..7
        let ts = (UInt32(pkt[4]) << 24) | (UInt32(pkt[5]) << 16) | (UInt32(pkt[6]) << 8) | UInt32(pkt[7])
        //print("ts=\(ts)")
        
        currentTimestamp = ts
        
        //print("end=\(end) offset=\(offset)") v 12
        guard end > offset else { return }
        let payload = pkt.subdata(in: offset..<end)
        
        // Quantization Table expected:
        guard payload.count >= 2 else { return }
        
        do {
            let jpeg = try push(payload: payload, rtpTimestamp: ts, marker: marker)
            if (marker && jpeg != nil) {
                onJPEGFrame(jpeg!, ts)
            }
        } catch  {
            print("parseRFC2435Header error \(error)")
        }
    }
    
    func parseRFC2435Header(_ payload: Data) throws -> RFC2435Header {
        guard payload.count >= 8 else { throw NSError(domain: "RTPJPEG", code: 1) }
        
        let ts  = payload.u8(0)
        let o1  = Int(payload.u8(1))
        let o2  = Int(payload.u8(2))
        let o3  = Int(payload.u8(3))
        let off = (o1 << 16) | (o2 << 8) | o3
        
        let type = payload.u8(4)
        let q    = payload.u8(5)
        let w    = Int(payload.u8(6)) * 8
        let h    = Int(payload.u8(7)) * 8
        print("RFC2435 off=\(off) w=\(w) h=\(h) q=\(q) ts=\(ts)")
        
        return .init(typeSpecific: ts, fragmentOffset: off, type: type, q: q, width: w, height: h)
    }
        
    func push(payload: Data, rtpTimestamp: UInt32, marker: Bool) throws -> Data? {
        let h = try parseRFC2435Header(payload)
        var idx = 8
        print("off=\(h.fragmentOffset) w=\(h.width) h=\(h.height) q=\(h.q) marker=\(marker)")

        // If timestamp is changed, reset frame
        if currentTimestamp != nil, currentTimestamp != rtpTimestamp, h.fragmentOffset != 0 {
            reset()
        }
        if currentTimestamp == nil { currentTimestamp = rtpTimestamp }
        
        if h.fragmentOffset == 0 {
            // new frame
            reset(keepTimestamp: true)
            width = h.width
            height = h.height
            
            _ = payload.subdata(in: idx..<idx+2)
            idx = idx + 2
            _ = payload.subdata(in: idx..<idx+2)
            idx = idx + 2
            qTables = payload.subdata(in: idx..<idx+128)
            idx = idx + 128
            
            // Estimaged size : 64KB
            expectedSizeHint = max(expectedSizeHint, 64 * 1024)
            frameBuffer = Data(count: expectedSizeHint)
        }
        
        let jpegFragment = payload.subdata(in: idx..<payload.count)
        
        let off = h.fragmentOffset
        let need = off + jpegFragment.count
        if frameBuffer.count < need {
            frameBuffer.append(Data(count: need - frameBuffer.count))
        }
        frameBuffer.replaceSubrange(off..<off+jpegFragment.count, with: jpegFragment)
        
        if marker {
            // ここでフレーム確定：RFC2435の情報から JPEGファイルを組み立てる
            let jpegData = buildJPEG(width: width, height: height, qTables: qTables, scanData: frameBuffer, scanDataSize: need)
            reset()
            return jpegData
        }
        
        return nil
    }
    
    private func reset(keepTimestamp: Bool = false) {
        if !keepTimestamp { currentTimestamp = nil }
        frameBuffer.removeAll(keepingCapacity: true)
        qTables = Data()
        width = 0; height = 0
    }
    
    func buildJPEG(width: Int, height: Int, qTables: Data, scanData: Data, scanDataSize: Int) -> Data {
        var out = Data()

        out.append(contentsOf:[0xFF, 0xD8]) // SOI
        out.append(jfifAPP0()) // optional
        out.append(dqtMarker(qTables:qTables))
        out.append(makeSOF0(width: width, height: height, sampling: .yuv422))

        out.append(standardDHT()) // ★これが無いと失敗することが多い
        out.append(sos())         // Start of Scan

        out.append(scanData.subdata(in: 0..<scanDataSize))
        out.append(contentsOf:[0xFF, 0xD9])  // EOI
        return out
    }

    private func jfifAPP0() -> Data {
        // APP0 JFIF (最小)
        return Data([
            0xFF,0xE0, 0x00,0x10,
            0x4A,0x46,0x49,0x46,0x00,
            0x01,0x01,
            0x00,
            0x00,0x01, 0x00,0x01,
            0x00,0x00
        ])
    }

    private func dqtMarker(qTables: Data) -> Data {
        // 2 tables: 0 (luma), 1 (chroma)
        var body = Data()
        body.append(0x00) // Pq/Tq = 0, id=0
        body.append(qTables.subdata(in: 0..<64))
        body.append(0x01) // Pq/Tq = 0, id=1
        body.append(qTables.subdata(in: 64..<128))

        var out = Data([0xFF, 0xDB])
        out.append(uint16be(UInt16(body.count + 2)))
        out.append(body)
        return out
    }

    enum JpegSampling {
        case yuv422
        case yuv420
        case yuv444
    }

    func makeSOF0(width: Int, height: Int, sampling: JpegSampling) -> Data {
        // SOF0 payload length = 17 (0x0011)
        // precision=8
        // components=3 (YCbCr)
        var d = Data([0xFF, 0xC0, 0x00, 0x11, 0x08])

        d.append(UInt8((height >> 8) & 0xFF))
        d.append(UInt8(height & 0xFF))
        d.append(UInt8((width >> 8) & 0xFF))
        d.append(UInt8(width & 0xFF))

        d.append(0x03) // components

        let ySampling: UInt8
        switch sampling {
        case .yuv422: ySampling = 0x21 // H=2 V=1  (4:2:2)
        case .yuv420: ySampling = 0x22 // H=2 V=2  (4:2:0)
        case .yuv444: ySampling = 0x11 // H=1 V=1  (4:4:4)
        }

        // Y
        d.append(contentsOf: [0x01, ySampling, 0x00]) // compId=1, samp, QT=0
        // Cb
        d.append(contentsOf: [0x02, 0x11, 0x01])      // compId=2, samp=1x1, QT=1
        // Cr
        d.append(contentsOf: [0x03, 0x11, 0x01])      // compId=3, samp=1x1, QT=1

        return d
    }
    
    private func sof0_old(width: Int, height: Int) -> Data {
        // Baseline DCT, 3 components (YCbCr), samplingはよくある 4:2:0 を仮置き
        let w = UInt16(width), h = UInt16(height)

        return Data([
            0xFF,0xC0, 0x00,0x11,
            0x08,
            UInt8(h >> 8), UInt8(h & 0xFF),
            UInt8(w >> 8), UInt8(w & 0xFF),
            0x03,        // components
            0x01, 0x21, 0x00, // Y  (H=2,V=2) QT=0, 4:2:2
            0x02, 0x11, 0x01, // Cb (H=1,V=1) QT=1
            0x03, 0x11, 0x01  // Cr (H=1,V=1) QT=1
        ])
    }

    /// Standard JPEG Huffman tables (Annex K.3 / "standard" DHT used by many MJPEG streams)
    /// Returns a complete DHT segment starting with 0xFFC4.
    func standardDHT() -> Data {
        // This is a well-known constant blob used in many MJPEG implementations.
        // It defines: DC Luma (0), AC Luma (0x10), DC Chroma (1), AC Chroma (0x11)
        let bytes: [UInt8] = [
            0xFF,0xC4,0x01,0xA2,

            // DC Luma table (0)
            0x00,
            0x00,0x01,0x05,0x01,0x01,0x01,0x01,0x01,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
            0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0A,0x0B,

            // AC Luma table (0x10)
            0x10,
            0x00,0x02,0x01,0x03,0x03,0x02,0x04,0x03,0x05,0x05,0x04,0x04,0x00,0x00,0x01,0x7D,
            0x01,0x02,0x03,0x00,0x04,0x11,0x05,0x12,0x21,0x31,0x41,0x06,0x13,0x51,0x61,0x07,
            0x22,0x71,0x14,0x32,0x81,0x91,0xA1,0x08,0x23,0x42,0xB1,0xC1,0x15,0x52,0xD1,0xF0,
            0x24,0x33,0x62,0x72,0x82,0x09,0x0A,0x16,0x17,0x18,0x19,0x1A,0x25,0x26,0x27,0x28,
            0x29,0x2A,0x34,0x35,0x36,0x37,0x38,0x39,0x3A,0x43,0x44,0x45,0x46,0x47,0x48,0x49,
            0x4A,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5A,0x63,0x64,0x65,0x66,0x67,0x68,0x69,
            0x6A,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7A,0x83,0x84,0x85,0x86,0x87,0x88,0x89,
            0x8A,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9A,0xA2,0xA3,0xA4,0xA5,0xA6,0xA7,
            0xA8,0xA9,0xAA,0xB2,0xB3,0xB4,0xB5,0xB6,0xB7,0xB8,0xB9,0xBA,0xC2,0xC3,0xC4,0xC5,
            0xC6,0xC7,0xC8,0xC9,0xCA,0xD2,0xD3,0xD4,0xD5,0xD6,0xD7,0xD8,0xD9,0xDA,0xE1,0xE2,
            0xE3,0xE4,0xE5,0xE6,0xE7,0xE8,0xE9,0xEA,0xF1,0xF2,0xF3,0xF4,0xF5,0xF6,0xF7,0xF8,
            0xF9,0xFA,

            // DC Chroma table (1)
            0x01,
            0x00,0x03,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x00,0x00,0x00,0x00,0x00,
            0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0A,0x0B,

            // AC Chroma table (0x11)
            0x11,
            0x00,0x02,0x01,0x02,0x04,0x04,0x03,0x04,0x07,0x05,0x04,0x04,0x00,0x01,0x02,0x77,
            0x00,0x01,0x02,0x03,0x11,0x04,0x05,0x21,0x31,0x06,0x12,0x41,0x51,0x07,0x61,0x71,
            0x13,0x22,0x32,0x81,0x08,0x14,0x42,0x91,0xA1,0xB1,0xC1,0x09,0x23,0x33,0x52,0xF0,
            0x15,0x62,0x72,0xD1,0x0A,0x16,0x24,0x34,0xE1,0x25,0xF1,0x17,0x18,0x19,0x1A,0x26,
            0x27,0x28,0x29,0x2A,0x35,0x36,0x37,0x38,0x39,0x3A,0x43,0x44,0x45,0x46,0x47,0x48,
            0x49,0x4A,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5A,0x63,0x64,0x65,0x66,0x67,0x68,
            0x69,0x6A,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7A,0x82,0x83,0x84,0x85,0x86,0x87,
            0x88,0x89,0x8A,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9A,0xA2,0xA3,0xA4,0xA5,
            0xA6,0xA7,0xA8,0xA9,0xAA,0xB2,0xB3,0xB4,0xB5,0xB6,0xB7,0xB8,0xB9,0xBA,0xC2,0xC3,
            0xC4,0xC5,0xC6,0xC7,0xC8,0xC9,0xCA,0xD2,0xD3,0xD4,0xD5,0xD6,0xD7,0xD8,0xD9,0xDA,
            0xE2,0xE3,0xE4,0xE5,0xE6,0xE7,0xE8,0xE9,0xEA,0xF2,0xF3,0xF4,0xF5,0xF6,0xF7,0xF8,
            0xF9,0xFA
        ]
        return Data(bytes)
    }

    private func sos() -> Data {
        // Start of Scan (3 components)
        return Data([
            0xFF,0xDA, 0x00,0x0C,
            0x03,
            0x01,0x00,
            0x02,0x11,
            0x03,0x11,
            0x00,0x3F,0x00
        ])
    }

    private func uint16be(_ v: UInt16) -> Data {
        Data([UInt8(v >> 8), UInt8(v & 0xFF)])
    }
}

extension Data {
    func u8(_ i: Int) -> UInt8 { self[self.index(self.startIndex, offsetBy: i)] }
}
