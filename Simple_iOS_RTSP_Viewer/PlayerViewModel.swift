//
//  PlayerViewModel.swift
//  Simple_iOS_RTSP_Viewer
//
//  Created by Toru Ishihara on 2025/12/12.
//

import Foundation
import Combine
import CoreMedia

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var statusText: String

    private var client: RTSPClient?
    private var rtp: RTPH264Receiver?
    private var rtcp: UDPReceiver?
    private var decoder: H264Decoder?

    init(statusText: String = "Idle") {
        self.statusText = statusText
    }

    func connect(url: String) async {
        do {
            statusText = "Connecting..."
            
            rtp = RTPH264Receiver(port: 51500)
            try rtp!.start() { rtpPacket,ts  in
                print("VM rtp Packet size=\(rtpPacket.count)")
                print(rtpPacket.hexDump())
                let preferredTimescale: CMTimeScale = 1_000_000 // Microsecond precision
                let cmTime = CMTime(seconds: Double(ts), preferredTimescale: preferredTimescale)
                do {
                    try self.decoder!.decodeNAL(rtpPacket, pts: cmTime)
                } catch {
                    print("decodeNAL error: \(error)")
                }
            }
            
            rtcp = UDPReceiver()
            if (rtcp == nil) {
                print("RTCP receiver not created")
                return
            }
            rtcp!.start(port:51501) { rtcpPacket in
                print("rtcp!.start", rtcpPacket)
            }
            
            client = RTSPClient(urlString: url, rtpPort:51500)
            if (client == nil) {
                print("RTSPClient not created")
                return
            }
            await client!.connect()
            let (sps,pps) = await client!.setupVideo()
            statusText = "Connected"
            
            decoder = H264Decoder()
            if (decoder == nil) {
                print("H264Decoder not created")
                return
            }
            decoder!.onFrame = { [weak self] pixelBuffer, pts in
                guard let self else { return }
                // Update published state, or forward to a renderer
                printPixelBufferInfo(pixelBuffer, pts: pts)
            }
            try decoder!.configure(sps: sps, pps: pps)
            await client!.playVideo()
        } catch {
            print("some error failed:", error)
        }
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        statusText = "Idle"
    }
    
    func printPixelBufferInfo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        let ptsSec = CMTimeGetSeconds(pts)

        print("""
          Decoded Frame
          Size      : \(width)x\(height)
          PTS       : \(ptsSec)s
          Planes    : \(CVPixelBufferGetPlaneCount(pixelBuffer))
        """)
    }
}

