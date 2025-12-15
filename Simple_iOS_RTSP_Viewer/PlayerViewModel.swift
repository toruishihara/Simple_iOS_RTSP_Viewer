//
//  PlayerViewModel.swift
//  Simple_iOS_RTSP_Viewer
//
//  Created by Toru Ishihara on 2025/12/12.
//

import Foundation
import Combine

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var statusText: String

    private var client: RTSPClient?
    private var rtp: UDPReceiver?
    private var rtcp: UDPReceiver?

    init(statusText: String = "Idle") {
        self.statusText = statusText
    }

    func connect(url: String) async {
        statusText = "Connecting..."
        //client?.disconnect()
        rtp = UDPReceiver()
        if (rtp == nil) {
            print("RTP receiver not created")
            return
        }
        rtp!.start(port:51500) { rtpPacket in
            print("parse RTP header, payload: \(rtpPacket)")
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
        await client?.connect()
        //usleep(100_000)  // microseconds
        await client?.start()
        statusText = "Connected"
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        statusText = "Idle"
    }
}
