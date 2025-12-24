//
//  MJPEGDecoder.swift
//  Simple_iOS_RTSP_Viewer
//
//  Created by Toru Ishihara on 2025/12/23.
//

import Foundation
import ImageIO
import CoreGraphics
import VideoToolbox
import CoreMedia

final class MJPEGDecoder {
    enum DecodeError: Error { case invalidJPEG }
    
    /// Decode one JPEG frame (Data) into CGImage
    func decodeJPEG(_ jpeg: Data) throws -> CGImage {
        //print(jpeg.hexDump(max:jpeg.count))

        let cfData = jpeg as CFData
        guard let src = CGImageSourceCreateWithData(cfData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            print("JPEG decode failed")
            throw DecodeError.invalidJPEG
        }
        print("JPEG decode success")
        return img
    }
}
