//
//  Utils.swift
//  Simple_iOS_RTSP_Viewer
//
//  Created by Toru Ishihara on 2025/12/17.
//

import Foundation

extension Data {
    func hexDump(max: Int = 128) -> String {
        self.prefix(max).map {
            String(format: "%02X", $0)
        }.joined(separator: " ")
    }
}
