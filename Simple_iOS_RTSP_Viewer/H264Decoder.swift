//
//  H264Decoder.swift
//  Simple_iOS_RTSP_Viewer
//
//  Created by Toru Ishihara on 2025/12/17.
//

import Foundation
import VideoToolbox
import CoreMedia

final class H264Decoder {
    private var formatDesc: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    /// Called on decoded frames (CVPixelBuffer is in the decoder’s output format, usually NV12).
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    enum DecoderError: Error {
        case missingSPSPPS
        case formatDescriptionCreateFailed(OSStatus)
        case sessionCreateFailed(OSStatus)
        case blockBufferCreateFailed(OSStatus)
        case sampleBufferCreateFailed(OSStatus)
        case decodeFailed(OSStatus)
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        if let s = session {
            VTDecompressionSessionInvalidate(s)
            session = nil
            formatDesc = nil
        }
    }

    // MARK: - Configure with SPS/PPS (Annex-B NAL payload bytes, WITHOUT 0x00000001)

    func configure(sps: Data, pps: Data) throws {
        invalidate()

        let status = sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                let paramSetPointers: [UnsafePointer<UInt8>] = [
                    spsPtr.bindMemory(to: UInt8.self).baseAddress!,
                    ppsPtr.bindMemory(to: UInt8.self).baseAddress!
                ]
                let paramSetSizes: [Int] = [sps.count, pps.count]

                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: paramSetPointers,
                    parameterSetSizes: paramSetSizes,
                    nalUnitHeaderLength: 4, // AVCC uses 4-byte length prefix
                    formatDescriptionOut: &self.formatDesc
                )
            }
        }

        guard status == noErr else { throw DecoderError.formatDescriptionCreateFailed(status) }
        guard let formatDesc else { throw DecoderError.missingSPSPPS }

        let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
        let width = Int(dims.width)
        let height = Int(dims.height)
        print("H.264 video size: \(width)x\(height)")
        
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionOutputCallback,
            decompressionOutputRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        let decoderSpec: [NSString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: false
        ]
        
        // Ask for a CVPixelBuffer output (NV12 typically).
        let attrs: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]

        print("Calling VTDecompressionSessionCreate")
        let sessStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &self.session
        )
        print("VTDecompressionSessionCreate status=\(sessStatus)")

        guard sessStatus == noErr else { throw DecoderError.sessionCreateFailed(sessStatus) }
    }

    // MARK: - Decode a single *complete* NAL unit

    /// Decode one complete NAL unit (e.g., IDR, non-IDR slice, SPS/PPS, SEI).
    /// `nal` should be raw NAL bytes WITHOUT Annex-B start code.
    func decodeNAL(_ nal: Data, pts: CMTime) throws {
        guard let session, let formatDesc else { throw DecoderError.missingSPSPPS }

        // VideoToolbox expects AVCC: [4-byte length][NAL bytes]
        //var avcc = Data()
        //var lenBE = UInt32(nal.count).bigEndian
        //withUnsafeBytes(of: &lenBE) { avcc.append(contentsOf: $0) }
        //avcc.append(nal)

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: nal.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: nal.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == noErr, let block else { throw DecoderError.blockBufferCreateFailed(status) }

        status = nal.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: nal.count
            )
        }
        guard status == noErr else { throw DecoderError.blockBufferCreateFailed(status) }

        var sample: CMSampleBuffer?
        var sampleSize = nal.count
        print("Calling CMSampleBufferCreateReady")
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: [CMSampleTimingInfo(duration: .invalid,
                                                 presentationTimeStamp: pts,
                                                 decodeTimeStamp: .invalid)],
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        print("CMSampleBufferCreateReady status=\(status)")
        guard status == noErr, let sample else { throw DecoderError.sampleBufferCreateFailed(status) }

        var infoFlags = VTDecodeInfoFlags()
        print("Calling VTDecompressionSessionDecodeFrame")
        status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        print("VTDecompressionSessionDecodeFrame status=\(status)")
        // Some streams decode async; noErr is still correct.
        guard status == noErr else { throw DecoderError.decodeFailed(status) }
    }
}

// MARK: - Output callback

private func decompressionOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    print("decompressionOutputCallback called status=\(status)")
    guard status == noErr,
          let refCon = decompressionOutputRefCon,
          let imageBuffer = imageBuffer else { return }

    let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()
    decoder.onFrame?(imageBuffer, presentationTimeStamp)
}
