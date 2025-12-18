//
//  UDPReceiver.swift
//  Simple_iOS_RTSP_Viewer
//
//  Created by Toru Ishihara on 2025/12/15.
//
import SwiftUI
import Network

final class UDPReceiver {
    private var connection: NWConnection?
    
    func start(port: UInt16, onPacket: @escaping (Data) -> Void) {
        let params = NWParameters.udp
        let endpoint = NWEndpoint.hostPort(
            host: .ipv4(IPv4Address.any),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn
        
        conn.stateUpdateHandler = { state in
            print("UDP state:", state)
        }
        
        receiveLoop(onPacket: onPacket)
        conn.start(queue: .global())
    }
    
    private func receiveLoop(onPacket: @escaping (Data) -> Void) {
        connection?.receiveMessage { data, _, _, error in
            print("RTP loop \(data?.count ?? 0)")
            if let data = data {
                onPacket(data)
            }
            if error == nil {
                self.receiveLoop(onPacket: onPacket)
            }
        }
    }
    
    func stop() {
        connection?.cancel()
        connection = nil
    }
}
