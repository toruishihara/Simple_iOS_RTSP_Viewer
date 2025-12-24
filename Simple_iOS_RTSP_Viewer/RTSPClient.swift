//
//  RTSPClient.swift
//  Simple_iOS_RTSP_Viewer
//
//  Created by Toru Ishihara on 2025/12/12.
//

import Foundation
import CryptoKit

final class RTSPClient {
    private var client: TCPClient

    private var urlStr = ""
    private var userAgent = "LibVLC/3"
    private var host = ""
    private var port: UInt16 = 554
    private var path: String = "/"
    private var user = ""
    private var pass = ""
    private var realm = ""
    private var nonce = ""
    private var sessionID = ""

    private let rtpPort: UInt16
    private let rtcpPort: UInt16
    
    private var rtspURLNoCreds: String {
        "rtsp://\(host):\(port)\(path)"
    }
    
    private(set) var state: State = .idle
    private var onState: ((State) -> Void)?
    private var needAuth = false
    private var cseq = 1
    private var hasH264 = false
    private var hasMJPEG = false
    public var sps = Data()
    public var pps = Data()
    
    enum State {
        case idle
        case connecting
        case connected
        case error(String)
    }
    enum RTSPError: Error {
        case notConnected
        case connectionClosed
    }
    
    init(urlString: String, rtpPort: UInt16, onState: ((State) -> Void)? = nil) {
        self.urlStr = urlString
        self.rtpPort = rtpPort
        self.rtcpPort = rtpPort + 1
        self.onState = onState
        if let url = URL(string: urlString) {
            host = url.host ?? ""
            port = UInt16(url.port ?? 554)
            path = url.path.isEmpty ? "/" : url.path
            user = url.user ?? ""
            pass = url.password ?? ""
 
            print("host:", host)
            print("port:", port)
            print("user:", user)
            print("password:", pass)
            print("path:", path)
            
            client = TCPClient(host: host, port: port)
        } else {
            client = TCPClient(host: "127.0.0.1", port: 554)
        }
    }
    
    func connect() async {
        guard case .idle = state else { return }
        
        setState(.connecting)
        
            do {
                try await self.client.connect()
            } catch {
                print("client.connect failed:", error)
            }            
    }
    
    func disconnect() {
        // TODO: stop network, stop decoder, release resources
        setState(.idle)
    }
    
    deinit {
        disconnect()
    }
    
    private func setState(_ s: State) {
        state = s
        onState?(s)
    }
        
    func setupVideo() async -> (hasH264:Bool, hasMJPEG:Bool) {
        do {
            let req0 =
"""
OPTIONS \(urlStr) RTSP/1.0\r\n
CSeq: \(cseq)\r\n
User-Agent: \(userAgent)\r\n
\r\n
"""
            //print("req0=\(req0)")
            try await client.send(req0)
            let res0 = try await client.readRTSPResponse()
            //print("res0=\(res0.header)")
            if (!res0.header.contains("200 OK") || !res0.header.contains("DESCRIBE") || !res0.header.contains("PLAY")) {
                return (false,false)
            }
            print("res0 incldues PLAY and DESCRIBE Continue")
            
            cseq = cseq + 1
            let req1 =
"""
DESCRIBE \(urlStr) RTSP/1.0\r\n
CSeq: \(cseq)\r\n
User-Agent: \(userAgent) \r\n
Accept: application/sdp\r\n
\r\n
"""
            //print("req1=\(req1)")
            try await client.send(req1)
            let res1 = try await client.readRTSPResponse()
            //print("res1=\(res1.header)")
            if (res1.header.contains("200 OK")) {
                needAuth = false
                print("res1 no Auth required. Continue")
            } else if (res1.header.contains("401")) {
                needAuth = true
                let params = parseDigestAuth(res1.header)
                if (params.nonce == nil || params.realm == nil) {
                    return (false,false)
                }
                realm = params.realm!
                nonce = params.nonce!
                print("res1 incldues nonce realm. Continue")
            }
            
            let res2 = try await sendAuthDescribe()
            //print("res2 header=\(res2.header)")
            let body2 = String(decoding: res2.body, as: UTF8.self)
            print("res2 body=\(body2)")
            var sps:Data = Data()
            var pps:Data = Data()
            for line in body2.split(separator: "\r\n") {
                //if line.contains("sprop-parameter-sets") {
                if line.starts(with: "m=video 0 RTP/AVP 96") {
                    hasH264 = true
                    print("DSP 96 line=\(line)")
                    (sps, pps) = try parseSpropParameterSets(fromFmtpLine: String(line))
                    print("SPS bytes:", sps.count, "PPS bytes:", pps.count)
                    print(sps.hexDump())
                    print(pps.hexDump())
                }
                if line.starts(with: "m=video 0 RTP/AVP 26") {
                    hasMJPEG = true
                    print("DSP 26 line=\(line)")
                }
            }
        } catch RTSPError.notConnected {
            print("RTSP error: not connected")
        } catch RTSPError.connectionClosed {
            print("RTSP error: connection closed")
        } catch {
            print("Unexpected error:", error)
        }
        if (hasH264 || hasMJPEG) {
            print("res2 incldues H264 SPS Continue")
            return (hasH264, hasMJPEG)
        } else {
            print("No H264 or MJPEG in the SDP")
            return (false,false)
        }
    }
    
    func sendAuthDescribe() async throws -> (header: String, body: Data) {
        cseq = cseq + 1
        let response = digestResponse(method: "DESCRIBE", uri: urlStr)
        let req =
"""
DESCRIBE \(urlStr) RTSP/1.0\r\n
CSeq: \(cseq)\r\n
Authorization: Digest username="\(user)", realm="\(realm)", nonce="\(nonce)", uri="\(urlStr)", response="\(response)"\r\n
User-Agent: \(userAgent)\r\n
Accept: application/sdp\r\n
\r\n
"""
        //print("sendAuthDescribe req=\(req)")
        try await client.send(req)
        let res = try await client.readRTSPResponse()
        return res
    }
    
    func playVideo() async throws {
        cseq = cseq + 1
        let response3 = digestResponse(method: "SETUP", uri: urlStr)
        let req3 =
"""
SETUP \(urlStr)/track0 RTSP/1.0\r\n
CSeq: \(cseq)\r\n
Authorization: Digest username="\(user)", realm="\(realm)", nonce="\(nonce)", uri="\(urlStr)", response="\(response3)"\r\n
User-Agent: \(userAgent)\r\n
Transport: RTP/AVP;unicast;client_port=\(rtpPort)-\(rtcpPort)\r\n
\r\n
"""
        let req3jpeg =
"""
SETUP \(urlStr) RTSP/1.0\r\n
CSeq: \(cseq)\r\n
User-Agent: \(userAgent)\r\n
Transport: RTP/AVP;unicast;client_port=\(rtpPort)-\(rtcpPort)\r\n
\r\n
"""
        if (hasH264) {
            try await client.send(req3)
        } else if (hasMJPEG) {
            try await client.send(req3jpeg)
        }
        let res3 = try await client.readRTSPResponse()
        sessionID = parseSessionID(res3.header)
        if (sessionID.isEmpty) {
            print("sessionID missing error")
            return
        }
        print("res3 incldues sessionID Continue")
        
        cseq = cseq + 1
        let response4 = digestResponse(method: "PLAY", uri: urlStr)
        let req4 =
"""
PLAY \(urlStr) RTSP/1.0\r\n
CSeq: \(cseq)\r\n
Authorization: Digest username="\(user)", realm="\(realm)", nonce="\(nonce)", uri="\(urlStr)", response="\(response4)"\r\n
User-Agent: \(userAgent)\r\n
Session: \(sessionID)\r\n
\r\n
"""
        let req4jpeg =
"""
PLAY \(urlStr) RTSP/1.0\r\n
CSeq: \(cseq)\r\n
User-Agent: \(userAgent)\r\n
Session: \(sessionID)\r\n
Range: npt=0.000-\r\n
\r\n
"""
        print("req4=\(req4)")
        if (hasH264) {
            try await client.send(req4)
        } else if (hasMJPEG) {
            try await client.send(req4jpeg)
        }
        let res4 = try await client.readRTSPResponse()
        print("res4 header=\(res4.header)")
    }
    
    func parseDigestAuth(_ header: String) -> (realm: String?, nonce: String?) {
        let pattern = #"realm="([^"]+)",\s*nonce="([^"]+)""#
        
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (nil, nil)
        }
        
        let range = NSRange(header.startIndex..., in: header)
        guard let match = regex.firstMatch(in: header, range: range) else {
            return (nil, nil)
        }
        
        let realmRange = Range(match.range(at: 1), in: header)
        let nonceRange = Range(match.range(at: 2), in: header)
        
        let realm = realmRange.map { String(header[$0]) }
        let nonce = nonceRange.map { String(header[$0]) }
        
        return (realm, nonce)
    }

    func parseContentLength(_ headerText: String) -> Int {
        // "Content-length: 631" or "Content-Length: 631"
        let lines = headerText.split(separator: "\r\n")
        for line in lines {
            if line.lowercased().hasPrefix("content-length:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
        }
        return 0
    }

    func parseSessionID(_ response: String) -> String {
        for line in response.split(separator: "\r\n") {
            if line.starts(with: "Session:") {
                // "Session: 6959...; timeout=60;"
                let value = line
                    .replacingOccurrences(of: "Session:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                return value.split(separator: ";").first.map(String.init)!
            }
        }
        return ""
    }

    func digestResponse(method: String, uri: String) -> String {
        let ha1 = md5Hex("\(user):\(realm):\(pass)")
        let ha2 = md5Hex("\(method):\(uri)")
        return md5Hex("\(ha1):\(nonce):\(ha2)")
    }
    

    enum SDPParseError: Error {
        case noSprop
        case invalidBase64
    }

    /// Returns (sps, pps) as raw NAL unit bytes (no 0x00000001 prefix).
    func parseSpropParameterSets(fromFmtpLine line: String) throws -> (Data, Data) {
        // Find "sprop-parameter-sets=...."
        guard let range = line.range(of: "sprop-parameter-sets=") else {
            throw SDPParseError.noSprop
        }
        var tail = String(line[range.upperBound...])

        // Cut at ';' if more parameters follow
        if let semi = tail.firstIndex(of: ";") {
            tail = String(tail[..<semi])
        }

        // tail is "BASE64_SPS,BASE64_PPS"
        let parts = tail.split(separator: ",", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { throw SDPParseError.noSprop }

        func b64ToData(_ s: Substring) throws -> Data {
            // Add padding if missing (common in SDP)
            var str = String(s)
            let rem = str.count % 4
            if rem != 0 { str += String(repeating: "=", count: 4 - rem) }

            guard let d = Data(base64Encoded: str) else {
                throw SDPParseError.invalidBase64
            }
            return d
        }

        let sps = try b64ToData(parts[0])
        let pps = try b64ToData(parts[1])
        return (sps, pps)
    }
    
    func md5Hex(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// ESP32-S3 RTSP camera, https://github.com/rzeldent/esp32cam-rtsp
// Client -> Server
//OPTIONS rtsp://192.168.0.14:554/mjpeg/1 RTSP/1.0
//CSeq: 2
//User-Agent: LibVLC/3.0.18 (LIVE555 Streaming Media v2016.11.28)
//
// Server -> Client
//RTSP/1.0 200 OK
//CSeq: 2
//Public: DESCRIBE, SETUP, TEARDOWN, PLAY, PAUSE
//
// Client -> Server
//DESCRIBE rtsp://192.168.0.14:554/mjpeg/1 RTSP/1.0
//CSeq: 3
//User-Agent: LibVLC/3.0.18 (LIVE555 Streaming Media v2016.11.28)
//Accept: application/sdp
//
// Server -> Client
//RTSP/1.0 200 OK
//CSeq: 3
//Date: Thu, Jan 01 1970 00:06:21 GMT
//Content-Base: rtsp://192.168.0.14:554/mjpeg/1/
//Content-Type: application/sdp
//Content-Length: 94
// (SDP body)
//v=0
//o=- 1085377743 1 IN IP4 192.168.0.14
//s=
//t=0 0
//m=video 0 RTP/AVP 26
//c=IN IP4 0.0.0.0
//
// Client -> Server
//SETUP rtsp://192.168.0.14:554/mjpeg/1/ RTSP/1.0
//CSeq: 4
//User-Agent: LibVLC/3.0.18 (LIVE555 Streaming Media v2016.11.28)
//Transport: RTP/AVP;unicast;client_port=53348-53349
//
// Server -> Client
//RTSP/1.0 200 OK
//CSeq: 4
//Date: Thu, Jan 01 1970 00:06:23 GMT
//Transport: RTP/AVP;unicast;destination=127.0.0.1;source=127.0.0.1;client_port=53348-53349;server_port=6970-6971
//Session: -2147430019
//
// Client -> Server
//PLAY rtsp://192.168.0.14:554/mjpeg/1/ RTSP/1.0
//CSeq: 5
//User-Agent: LibVLC/3.0.18 (LIVE555 Streaming Media v2016.11.28)
//Session: -2147430019
//Range: npt=0.000-
//
// Server -> Client
//RTSP/1.0 200 OK
//CSeq: 5
//Date: Thu, Jan 01 1970 00:06:24 GMT
//Range: npt=0.000-
//Session: -2147430019
//RTP-Info: url=rtsp://127.0.0.1:8554/mjpeg/1/track1
