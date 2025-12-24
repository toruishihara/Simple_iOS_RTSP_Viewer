//
//  PlayerViewModel.swift
//  Simple_iOS_RTSP_Viewer
//
//  Created by Toru Ishihara on 2025/12/12.
//

import Foundation
import Combine
import CoreMedia
import CoreImage

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var latestImage: CGImage?
    @Published var statusText: String
    
    // RTP port, you can change to any value if open
    private let RTPPort:UInt16 = 51500

    private let ciContext = CIContext()
    private var client: RTSPClient?
    private var rtpH264: RTPH264Receiver?
    private var rtpMJPEG: RTPMJPEGReceiver?
    private var rtcp: UDPReceiver?
    private var h264Decoder: H264Decoder?
    private var mjpegDecoder: MJPEGDecoder?

    init(statusText: String = "Idle") {
        self.statusText = statusText
    }
    func connect(url: String) async {
        do {
            statusText = "Connecting..."
            

            rtcp = UDPReceiver()
            if (rtcp == nil) {
                print("RTCP receiver not created")
                return
            }
            rtcp!.start(port:RTPPort + 1) { rtcpPacket in
                print("rtcp!.start", rtcpPacket)
            }
            
            client = RTSPClient(urlString: url, rtpPort:RTPPort)
            if (client == nil) {
                print("RTSPClient not created")
                return
            }
            await client!.connect()
            let res =  await client!.setupVideo()
            if (!res.hasH264 && !res.hasMJPEG) {
                print("setupVideo error")
                return
            }
            if (res.hasH264) {
                rtpH264 = RTPH264Receiver(port: RTPPort)
                try rtpH264!.start() { rtpPacket,ts  in
                    print("VM rtp Packet size=\(rtpPacket.count)")
                    print(rtpPacket.hexDump())
                    let preferredTimescale: CMTimeScale = 1_000_000 // Microsecond precision
                    let cmTime = CMTime(seconds: Double(ts), preferredTimescale: preferredTimescale)
                    do {
                        try self.h264Decoder!.decodeNAL(rtpPacket, pts: cmTime)
                    } catch {
                        print("decodeNAL error: \(error)")
                    }
                }
            } else if (res.hasMJPEG) {
                rtpMJPEG = RTPMJPEGReceiver(port: RTPPort)
                rtpMJPEG!.onJPEGFrame = { [weak self] jpegData, pts in
                    guard let self else { return }
                    // background work
                    Task.detached(priority: .userInitiated) {
                        do {
                            let img = try await self.mjpegDecoder!.decodeJPEG(jpegData)
                            await MainActor.run {
                                self.latestImage = img
                            }
                        } catch {
                            await MainActor.run {
                                self.statusText = "Decode failed: \(error)"
                            }
                        }
                    }
                }
                try rtpMJPEG!.start()
            }

            statusText = "Connected"
            
            if (res.hasH264) {
                h264Decoder = H264Decoder()
                if (h264Decoder == nil) {
                    print("H264Decoder not created")
                    return
                }
                h264Decoder!.onFrame = { [weak self] pixelBuffer, pts in
                    guard let self else { return }
                    Task { @MainActor in self.onDecodedFrame(pixelBuffer, pts: pts) }
                }
                try h264Decoder!.configure(sps: client!.sps, pps: client!.pps)
                try await client!.playVideo()
            } else if (res.hasMJPEG) {
                mjpegDecoder = MJPEGDecoder()
                if (mjpegDecoder == nil) {
                    print("H264Decoder not created")
                    return
                }
                try await client!.playVideo()
            }
        } catch {
            print("some error failed:", error)
        }
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        statusText = "Idle"
    }
    
    func onDecodedFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // If rotation/scale needed, apply transform here.

        if let cg = ciContext.createCGImage(ciImage, from: ciImage.extent) {
            self.latestImage = cg
        }
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

