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
    private let urlString: String
    private var host = ""
    private var port: Int = 554
    private var path: String = "/"
    private var username: String?
    private var password: String?
    
    private let rtpPort: Int
    private let rtcpPort: Int
    
    // e.g. "rtsp://192.168.0.120:554/live/ch1"
    private var rtspURLNoCreds: String {
        "rtsp://\(host):\(port)\(path)"
    }
    
    private(set) var state: State = .idle
    private var onState: ((State) -> Void)?
    
    //private var inputStream: InputStream?
    //private var outputStream: OutputStream?
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
    

    init(urlString: String, rtpPort: Int, onState: ((State) -> Void)? = nil) {
        self.urlString = urlString
        self.rtpPort = rtpPort
        self.rtcpPort = rtpPort + 1
        self.onState = onState
        if let url = URL(string: urlString) {
            host = url.host ?? ""
            port = url.port ?? 554
            path = url.path.isEmpty ? "/" : url.path
            username = url.user
            password = url.password
            
            print("host:", host)
            print("port:", port)
            print("user:", username ?? "")
            print("password:", password ?? "")
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
            
            //var readStream: Unmanaged<CFReadStream>?
            //var writeStream: Unmanaged<CFWriteStream>?
            
            //CFStreamCreatePairWithSocketToHost(
            //    nil,
            //    host as CFString,
            //    UInt32(port),
            //    &readStream,
            //    &writeStream
            //)
            
            //inputStream = readStream?.takeRetainedValue()
            //outputStream = writeStream?.takeRetainedValue()
            
            //inputStream?.open()
            //outputStream?.open()
            
            //setState(.connected)
        //}
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
        
    func start() async {
        let userAgent = "LibVLC/3.0.18 (LIVE555 Streaming Media v2016.11.28)"
        let user = "long"
        let pass = "short"
        let urlStr = "rtsp://192.168.0.120:554/live/ch1"
        
        let req0 =
"""
OPTIONS \(urlStr) RTSP/1.0\r\n
CSeq: 1\r\n
User-Agent: \(userAgent)\r\n
\r\n
"""
        do {
            try await client.send(req0)
            let resData0 = try await client.readUntil(
                Data("\r\n\r\n".utf8),
                timeoutSeconds: 5.0
            )
            let res0 = String(decoding: resData0, as: UTF8.self)
            print("res0=" + res0)
            if (!res0.contains("200 OK") || !res0.contains("DESCRIBE") || !res0.contains("PLAY")) {
                return
            }
            let req1 =
"""
DESCRIBE \(urlStr) RTSP/1.0\r\n
CSeq: 3\r\n
User-Agent: \(userAgent) \r\n
Accept: application/sdp\r\n
\r\n
"""

            try await client.send(req1)
            let resData1 = try await client.readUntil(
                Data("\r\n\r\n".utf8),
                timeoutSeconds: 5.0
            )
            let res1 = String(decoding: resData1, as: UTF8.self)
            print("res1=" + res1)
            if (!res1.contains("401")) {
                return
            }
            let params = parseDigestAuth(res1)
            if (params.nonce == nil || params.realm == nil) {
                return
            }
            let response2 = digestResponse(username: user, password: pass, realm: params.realm!, nonce: params.nonce!, method: "DESCRIBE", uri: urlStr)
            let req2 =
"""
DESCRIBE \(urlStr) RTSP/1.0\r\n
CSeq: 4\r\n
Authorization: Digest username="\(user)", realm="\(params.realm!)", nonce="\(params.nonce!)", uri="\(urlStr)", response="\(response2)"\r\n
User-Agent: \(userAgent)\r\n
Accept: application/sdp\r\n
\r\n
"""
            try await client.send(req2)
            let resData2 = try await client.readUntil(
                Data("\r\n\r\n".utf8),
                timeoutSeconds: 5.0
            )
            let res2 = String(decoding: resData2, as: UTF8.self)
            print("res2=" + res2)
            if (!res2.contains("200 OK")) {
                return
            }
            
            let response3 = digestResponse(username: user, password: pass, realm: params.realm!, nonce: params.nonce!, method: "SETUP", uri: urlStr)
            let req3 =
"""
SETUP \(urlStr)/track0 RTSP/1.0\r\n
CSeq: 5\r\n
Authorization: Digest username="\(user)", realm="\(params.realm!)", nonce="\(params.nonce!)", uri="\(urlStr)", response="\(response3)"\r\n
User-Agent: \(userAgent)\r\n
Transport: RTP/AVP;unicast;client_port=\(rtpPort)-\(rtcpPort)\r\n
\r\n
"""
            try await client.send(req3)
            let resData3 = try await client.readUntil(
                Data("\r\n\r\n".utf8),
                timeoutSeconds: 5.0
            )
            let res3 = String(decoding: resData3, as: UTF8.self)
            print("res3=" + res3)
            if (!res3.contains("200 OK")) {
                return
            }
        } catch RTSPError.notConnected {
            print("RTSP error: not connected")
        } catch RTSPError.connectionClosed {
            print("RTSP error: connection closed")
        } catch {
            print("Unexpected error:", error)
        }
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
    

    func digestResponse(username: String, password: String, realm: String, nonce: String,
                        method: String, uri: String) -> String {
        let ha1 = md5Hex("\(username):\(realm):\(password)")
        let ha2 = md5Hex("\(method):\(uri)")
        return md5Hex("\(ha1):\(nonce):\(ha2)")
    }
    
    func md5Hex(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}


// Client -> Server
//OPTIONS rtsp://192.168.0.120:554/live/ch1 RTSP/1.0
//CSeq: 2
//User-Agent: LibVLC/3.0.18 (LIVE555 Streaming Media v2016.11.28)

// Server -> Client
//RTSP/1.0 200 OK
//    CSeq: 2
//    Date: Fri, Dec 12 2025 00:55:52 GMT
//    Server: RTSP Server
//    Public: OPTIONS, DESCRIBE, SETUP, TEARDOWN, PLAY, PAUSE, GET_PARAMETER, SET_PARAMETER

// Client -> Server
//DESCRIBE rtsp://192.168.0.120:554/live/ch1 RTSP/1.0
//CSeq: 3
//User-Agent: LibVLC/3.0.18 (LIVE555 Streaming Media v2016.11.28)
//Accept: application/sdp

// Server -> Client
//RTSP/1.0 401 Unauthorized
//Server: RTSP Server
//CSeq: 3
//WWW-Authenticate: Digest realm="HHRtspd", nonce="6d99d427676c352fd9d15635e5da608b"

// Client -> Server
//Authorization: Digest username="TuPF7d6h", realm="HHRtspd", nonce="6d99d427676c352fd9d15635e5da608b", uri="rtsp://192.168.0.120:554/live/ch1", response="d64b48e2fba3302a1a7e1f4ad7997cb1"
//CSeq: 4
//User-Agent: LibVLC/3.0.18 (LIVE555 Streaming Media v2016.11.28)
//Accept: application/sdp

/* Server -> Client
 RTSP/1.0 200 OK
 CSeq: 4
 Date: Fri, Dec 12 2025 00:55:52 GMT
 Server: RTSP Server
 Content-type: application/sdp
 Content-length: 631
 
 v=0
 o=- 1765500952 1765500953 IN IP4 192.168.0.120
 s=streamed by RTSP server
 e=NONE
 b=AS:1088
 t=0 0
 m=video 0 RTP/AVP 96
 c=IN IP4 0.0.0.0
 b=AS:1024
 a=recvonly
 a=x-dimensions:640,360
 a=rtpmap:96 H264/90000
 a=control:track0
 a=fmtp:96 packetization-mode=1;profile-level-id=640016;sprop-parameter-sets=Z2QAFqw7UFAX/LCAAAADAIAAAA9C,aO484QBCQgCEhARMUhuTxXyfk/k/J8nm5MkkLCJCkJyeT6/J/X5PrycmpMA=
 m=audio 0 RTP/AVP 97
 c=IN IP4 0.0.0.0
 b=AS:64
 a=recvonly
 a=control:track1
 a=rtpmap:97 MPEG4-GENERIC/8000/1
 a=fmtp:97 profile-level-id=15;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config=1588;profile=1;
 */

/* Client -> Server
 SETUP rtsp://192.168.0.120:554/live/ch1/track0 RTSP/1.0
 CSeq: 5
 Authorization: Digest username="TuPF7d6h", realm="HHRtspd", nonce="6d99d427676c352fd9d15635e5da608b", uri="rtsp://192.168.0.120:554/live/ch1", response="3dc93376d770e74d7a6344a3c9bf76c1"
 User-Agent: LibVLC/3.0.18 (LIVE555 Streaming Media v2016.11.28)
 Transport: RTP/AVP;unicast;client_port=51748-51749
 */
// client listens 51748 for RTP
// client listens 51749 for RTCP

/* Server -> Client
RTSP/1.0 200 OK
CSeq: 5
Date: Fri, Dec 12 2025 00:55:52 GMT
Server: RTSP Server
Session: 6959096903166427680; timeout=60;
Transport: RTP/AVP/UDP;unicast;client_port=51748-51749;server_port=51628-51629;timeout=60
 */

/* Client -> Server
 SETUP rtsp://192.168.0.120:554/live/ch1/track1 RTSP/1.0
 CSeq: 6
 Authorization: Digest username="TuPF7d6h", realm="HHRtspd", nonce="6d99d427676c352fd9d15635e5da608b", uri="rtsp://192.168.0.120:554/live/ch1", response="3dc93376d770e74d7a6344a3c9bf76c1"
 User-Agent: LibVLC/3.0.18 (LIVE555 Streaming Media v2016.11.28)
 Transport: RTP/AVP;unicast;client_port=55650-55651
 Session: 6959096903166427680
 */

/*
 RTSP/1.0 200 OK
 CSeq: 6
 Date: Fri, Dec 12 2025 00:55:52 GMT
 Server: RTSP Server
 Session: 6959096903166427680; timeout=60;
 Transport: RTP/AVP/UDP;unicast;client_port=55650-55651;server_port=50362-50363;timeout=60
 */

