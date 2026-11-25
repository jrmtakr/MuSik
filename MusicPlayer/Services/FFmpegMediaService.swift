import AVFoundation
import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswscale
import UIKit

struct FFmpegMediaInfo {
    let durationSeconds: Double?
    let title: String?
    let artist: String?
    let album: String?
    let hasVideo: Bool
    let hasAudio: Bool
    let videoWidth: Int
    let videoHeight: Int
}

enum FFmpegMediaService {
    private static let networkInitOnce: Void = {
        avformat_network_init()
    }()

    static func probeMetadata(for url: URL, headers: [String: String]? = nil) -> FFmpegMediaInfo? {
        _ = networkInitOnce
        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
        var avOpts: OpaquePointer?

        if !url.isFileURL {
            if let headers, !headers.isEmpty {
                if let ua = headers["User-Agent"] {
                    av_dict_set(&avOpts, "user_agent", ua, 0)
                }
                let headerBlock = headers
                    .filter { $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame }
                    .map { "\($0.key): \($0.value)\r\n" }
                    .joined()
                if !headerBlock.isEmpty {
                    av_dict_set(&avOpts, "headers", headerBlock, 0)
                }
            }
            av_dict_set(&avOpts, "rw_timeout", "8000000", 0)
        }

        let target = url.isFileURL ? url.path : url.absoluteString
        let openResult = avformat_open_input(&fmtCtx, target, nil, &avOpts)
        av_dict_free(&avOpts)
        guard openResult == 0, let ctx = fmtCtx else {
            return nil
        }
        defer {
            var mutableCtx: UnsafeMutablePointer<AVFormatContext>? = ctx
            avformat_close_input(&mutableCtx)
        }

        guard avformat_find_stream_info(ctx, nil) >= 0 else {
            return nil
        }

        let rawDuration = ctx.pointee.duration
        let duration: Double? = (rawDuration != Int64.min && rawDuration > 0)
            ? Double(rawDuration) / Double(AV_TIME_BASE)
            : nil

        let tags = readDictionary(ctx.pointee.metadata)
        let title = tags["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (tags["artist"] ?? tags["album_artist"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = tags["album"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        var hasVideo = false
        var hasAudio = false
        var width = 0
        var height = 0

        for i in 0 ..< Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar else { continue }
            if codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                let disposition = stream.pointee.disposition
                if (disposition & AV_DISPOSITION_ATTACHED_PIC) == 0 {
                    hasVideo = true
                    width = max(width, Int(codecpar.pointee.width))
                    height = max(height, Int(codecpar.pointee.height))
                }
            } else if codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                hasAudio = true
            }
        }

        return FFmpegMediaInfo(
            durationSeconds: duration,
            title: title?.isEmpty == false ? title : nil,
            artist: artist?.isEmpty == false ? artist : nil,
            album: album?.isEmpty == false ? album : nil,
            hasVideo: hasVideo,
            hasAudio: hasAudio,
            videoWidth: width,
            videoHeight: height
        )
    }

    static func extractArtworkOrFrame(from url: URL, at seconds: Double = 1.0, maxDimension: Int = 640) -> UIImage? {
        _ = networkInitOnce
        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
        let target = url.isFileURL ? url.path : url.absoluteString
        guard avformat_open_input(&fmtCtx, target, nil, nil) == 0, let ctx = fmtCtx else {
            return nil
        }
        defer {
            var mutableCtx: UnsafeMutablePointer<AVFormatContext>? = ctx
            avformat_close_input(&mutableCtx)
        }
        guard avformat_find_stream_info(ctx, nil) >= 0 else { return nil }

        // Check embedded album cover first
        for i in 0 ..< Int(ctx.pointee.nb_streams) {
            if let stream = ctx.pointee.streams[i],
               (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0 {
                let pkt = stream.pointee.attached_pic
                if let data = pkt.data, pkt.size > 0 {
                    let imgData = Data(bytes: data, count: Int(pkt.size))
                    if let img = UIImage(data: imgData) {
                        return img
                    }
                }
            }
        }

        var videoStreamIdx: Int32 = -1
        for i in 0 ..< Int(ctx.pointee.nb_streams) {
            if let stream = ctx.pointee.streams[i],
               let par = stream.pointee.codecpar,
               par.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
               (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) == 0 {
                videoStreamIdx = Int32(i)
                break
            }
        }
        guard videoStreamIdx >= 0,
              let stream = ctx.pointee.streams[Int(videoStreamIdx)],
              let codecpar = stream.pointee.codecpar,
              let decoder = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            return nil
        }

        var codecCtx: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(decoder)
        guard let decCtx = codecCtx else { return nil }
        defer { avcodec_free_context(&codecCtx) }

        guard avcodec_parameters_to_context(decCtx, codecpar) >= 0,
              avcodec_open2(decCtx, decoder, nil) >= 0 else {
            return nil
        }

        if seconds > 0 {
            let dur = (ctx.pointee.duration != Int64.min && ctx.pointee.duration > 0)
                ? Double(ctx.pointee.duration) / Double(AV_TIME_BASE)
                : 0
            let clampedSec = dur > 0 ? min(seconds, max(0, dur * 0.5)) : seconds
            if clampedSec > 0.2 {
                let seekTarget = Int64(clampedSec * Double(AV_TIME_BASE))
                _ = av_seek_frame(ctx, -1, seekTarget, AVSEEK_FLAG_BACKWARD)
                avcodec_flush_buffers(decCtx)
            }
        }

        var pkt = av_packet_alloc()
        var frame = av_frame_alloc()
        defer {
            av_packet_free(&pkt)
            av_frame_free(&frame)
        }
        guard let pkt, let frame else { return nil }

        var attempts = 0
        while attempts < 180, av_read_frame(ctx, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            if pkt.pointee.stream_index != videoStreamIdx { continue }
            attempts += 1
            if avcodec_send_packet(decCtx, pkt) >= 0 {
                if avcodec_receive_frame(decCtx, frame) == 0 {
                    return imageFromAVFrame(frame.pointee, maxDimension: maxDimension)
                }
            }
        }
        _ = avcodec_send_packet(decCtx, nil)
        if avcodec_receive_frame(decCtx, frame) == 0 {
            return imageFromAVFrame(frame.pointee, maxDimension: maxDimension)
        }
        return nil
    }

    private static func imageFromAVFrame(_ frame: AVFrame, maxDimension: Int) -> UIImage? {
        let srcW = Int(frame.width)
        let srcH = Int(frame.height)
        guard srcW > 0, srcH > 0, frame.format >= 0 else { return nil }

        let scale = max(srcW, srcH) > maxDimension ? Double(maxDimension) / Double(max(srcW, srcH)) : 1.0
        let dstW = max(2, Int((Double(srcW) * scale).rounded()) & ~1)
        let dstH = max(2, Int((Double(srcH) * scale).rounded()) & ~1)

        guard let swsCtx = sws_getContext(
            Int32(srcW),
            Int32(srcH),
            AVPixelFormat(rawValue: frame.format),
            Int32(dstW),
            Int32(dstH),
            AV_PIX_FMT_RGBA,
            SWS_BILINEAR,
            nil,
            nil,
            nil
        ) else {
            return nil
        }
        defer { sws_freeContext(swsCtx) }

        let bytesPerRow = dstW * 4
        var rgbaBuffer = [UInt8](repeating: 0, count: bytesPerRow * dstH)

        let srcPointers: [UnsafePointer<UInt8>?] = [
            UnsafePointer(frame.data.0),
            UnsafePointer(frame.data.1),
            UnsafePointer(frame.data.2),
            UnsafePointer(frame.data.3)
        ]
        var srcLinesizes: [Int32] = [
            frame.linesize.0,
            frame.linesize.1,
            frame.linesize.2,
            frame.linesize.3
        ]

        rgbaBuffer.withUnsafeMutableBufferPointer { bufPtr in
            var dstPointers: [UnsafeMutablePointer<UInt8>?] = [bufPtr.baseAddress, nil, nil, nil]
            var dstLinesizes: [Int32] = [Int32(bytesPerRow), 0, 0, 0]
            sws_scale(
                swsCtx,
                srcPointers,
                &srcLinesizes,
                0,
                Int32(srcH),
                &dstPointers,
                &dstLinesizes
            )
        }

        let cfData = Data(rgbaBuffer) as CFData
        guard let provider = CGDataProvider(data: cfData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cgImage = CGImage(
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Remuxes an input container (such as MPEG-TS / local HLS / MKV / FLV with compatible H264/HEVC+AAC) into MP4.
    /// Does not require re-encoding. Returns false if codec combination isn't natively valid inside MP4.
    static func remuxToMP4(inputURL: URL, outputURL: URL, allowAllHLSExtensions: Bool = false) -> Bool {
        _ = networkInitOnce
        var inCtx: UnsafeMutablePointer<AVFormatContext>?
        var inOpts: OpaquePointer?
        if allowAllHLSExtensions {
            av_dict_set(&inOpts, "allowed_extensions", "ALL", 0)
            av_dict_set(&inOpts, "protocol_whitelist", "file,crypto,data", 0)
        }

        let inPath = inputURL.isFileURL ? inputURL.path : inputURL.absoluteString
        let openRet = avformat_open_input(&inCtx, inPath, nil, &inOpts)
        av_dict_free(&inOpts)
        guard openRet == 0, let inputFmtCtx = inCtx else { return false }
        defer {
            var ctx: UnsafeMutablePointer<AVFormatContext>? = inputFmtCtx
            avformat_close_input(&ctx)
        }

        guard avformat_find_stream_info(inputFmtCtx, nil) >= 0 else { return false }

        var outCtx: UnsafeMutablePointer<AVFormatContext>?
        let outPath = outputURL.path
        guard avformat_alloc_output_context2(&outCtx, nil, "mp4", outPath) >= 0,
              let outputFmtCtx = outCtx else {
            return false
        }

        var closedCleanly = false
        defer {
            if !closedCleanly {
                if let pb = outputFmtCtx.pointee.pb {
                    var pbCopy: UnsafeMutablePointer<AVIOContext>? = pb
                    avio_closep(&pbCopy)
                    outputFmtCtx.pointee.pb = nil
                }
                avformat_free_context(outputFmtCtx)
            }
        }

        let inputFormatName = inputFmtCtx.pointee.iformat?.pointee.name.flatMap { String(cString: $0) } ?? ""
        let isMPEGTS = inputFormatName.contains("mpegts") || inputFormatName.contains("hls")

        var streamMapping = [Int32: Int32]()
        var aacBSFs = [Int32: UnsafeMutablePointer<AVBSFContext>]()
        defer {
            for bsf in aacBSFs.values {
                var ptr: UnsafeMutablePointer<AVBSFContext>? = bsf
                av_bsf_free(&ptr)
            }
        }

        var nextOutIndex: Int32 = 0
        for i in 0 ..< Int(inputFmtCtx.pointee.nb_streams) {
            guard let inStream = inputFmtCtx.pointee.streams[i],
                  let codecpar = inStream.pointee.codecpar else { continue }
            let type = codecpar.pointee.codec_type
            guard type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO else { continue }
            if type == AVMEDIA_TYPE_VIDEO && (inStream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0 {
                continue
            }

            let codecID = codecpar.pointee.codec_id
            let supportedInMP4: Bool
            if type == AVMEDIA_TYPE_VIDEO {
                supportedInMP4 = [AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_MPEG4].contains(codecID)
            } else {
                supportedInMP4 = [AV_CODEC_ID_AAC, AV_CODEC_ID_MP3, AV_CODEC_ID_ALAC, AV_CODEC_ID_FLAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3].contains(codecID)
            }
            guard supportedInMP4 else { continue }

            guard let outStream = avformat_new_stream(outputFmtCtx, nil) else { continue }
            guard avcodec_parameters_copy(outStream.pointee.codecpar, codecpar) >= 0 else { continue }

            if codecID == AV_CODEC_ID_HEVC {
                outStream.pointee.codecpar.pointee.codec_tag = CMFormatDescription.MediaSubType.hevc.rawValue.bigEndian
            } else {
                outStream.pointee.codecpar.pointee.codec_tag = 0
            }

            if type == AVMEDIA_TYPE_AUDIO && codecID == AV_CODEC_ID_AAC && isMPEGTS,
               let filter = av_bsf_get_by_name("aac_adtstoasc") {
                var bsf: UnsafeMutablePointer<AVBSFContext>?
                if av_bsf_alloc(filter, &bsf) >= 0, let bsf {
                    avcodec_parameters_copy(bsf.pointee.par_in, codecpar)
                    bsf.pointee.time_base_in = inStream.pointee.time_base
                    if av_bsf_init(bsf) >= 0 {
                        avcodec_parameters_copy(outStream.pointee.codecpar, bsf.pointee.par_out)
                        aacBSFs[Int32(i)] = bsf
                    } else {
                        var freePtr: UnsafeMutablePointer<AVBSFContext>? = bsf
                        av_bsf_free(&freePtr)
                    }
                }
            }

            streamMapping[Int32(i)] = nextOutIndex
            nextOutIndex += 1
        }

        guard nextOutIndex > 0 else { return false }

        if let flags = outputFmtCtx.pointee.oformat?.pointee.flags, (flags & AVFMT_NOFILE) == 0 {
            var pb: UnsafeMutablePointer<AVIOContext>?
            guard avio_open(&pb, outPath, AVIO_FLAG_WRITE) >= 0 else {
                return false
            }
            outputFmtCtx.pointee.pb = pb
        }

        var muxOpts: OpaquePointer?
        av_dict_set(&muxOpts, "movflags", "+faststart", 0)
        let hdrRet = avformat_write_header(outputFmtCtx, &muxOpts)
        av_dict_free(&muxOpts)
        guard hdrRet >= 0 else {
            return false
        }

        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        guard let pkt else { return false }

        var lastDtsByOutStream = [Int32: Int64]()

        while av_read_frame(inputFmtCtx, pkt) >= 0 {
            let inIndex = pkt.pointee.stream_index
            guard let outIndex = streamMapping[inIndex],
                  let inStream = inputFmtCtx.pointee.streams[Int(inIndex)],
                  let outStream = outputFmtCtx.pointee.streams[Int(outIndex)] else {
                av_packet_unref(pkt)
                continue
            }

            if let bsf = aacBSFs[inIndex] {
                if av_bsf_send_packet(bsf, pkt) >= 0 {
                    av_packet_unref(pkt)
                    while av_bsf_receive_packet(bsf, pkt) >= 0 {
                        writeRescaledPacket(
                            pkt,
                            inTimeBase: bsf.pointee.time_base_out,
                            outTimeBase: outStream.pointee.time_base,
                            outIndex: outIndex,
                            outCtx: outputFmtCtx,
                            lastDtsByOutStream: &lastDtsByOutStream
                        )
                        av_packet_unref(pkt)
                    }
                } else {
                    av_packet_unref(pkt)
                }
            } else {
                writeRescaledPacket(
                    pkt,
                    inTimeBase: inStream.pointee.time_base,
                    outTimeBase: outStream.pointee.time_base,
                    outIndex: outIndex,
                    outCtx: outputFmtCtx,
                    lastDtsByOutStream: &lastDtsByOutStream
                )
                av_packet_unref(pkt)
            }
        }

        let trailerRet = av_write_trailer(outputFmtCtx)
        if let pb = outputFmtCtx.pointee.pb {
            var pbCopy: UnsafeMutablePointer<AVIOContext>? = pb
            avio_closep(&pbCopy)
            outputFmtCtx.pointee.pb = nil
        }
        avformat_free_context(outputFmtCtx)
        closedCleanly = true
        return trailerRet >= 0
    }

    private static func writeRescaledPacket(
        _ pkt: UnsafeMutablePointer<AVPacket>,
        inTimeBase: AVRational,
        outTimeBase: AVRational,
        outIndex: Int32,
        outCtx: UnsafeMutablePointer<AVFormatContext>,
        lastDtsByOutStream: inout [Int32: Int64]
    ) {
        av_packet_rescale_ts(pkt, inTimeBase, outTimeBase)
        pkt.pointee.stream_index = outIndex
        pkt.pointee.pos = -1

        if pkt.pointee.dts == Int64.min {
            pkt.pointee.dts = (lastDtsByOutStream[outIndex] ?? -1) + 1
        }
        if let prevDts = lastDtsByOutStream[outIndex], pkt.pointee.dts <= prevDts {
            pkt.pointee.dts = prevDts + 1
        }
        if pkt.pointee.pts == Int64.min || pkt.pointee.pts < pkt.pointee.dts {
            pkt.pointee.pts = pkt.pointee.dts
        }
        lastDtsByOutStream[outIndex] = pkt.pointee.dts

        _ = av_interleaved_write_frame(outCtx, pkt)
    }

    private static func readDictionary(_ dict: OpaquePointer?) -> [String: String] {
        guard let dict else { return [:] }
        var result: [String: String] = [:]
        var entry: UnsafeMutablePointer<AVDictionaryEntry>?
        while true {
            entry = av_dict_get(dict, "", entry, AV_DICT_IGNORE_SUFFIX)
            guard let current = entry else { break }
            if let keyPtr = current.pointee.key, let valPtr = current.pointee.value {
                let key = String(cString: keyPtr).lowercased()
                let value = String(cString: valPtr)
                result[key] = value
            }
        }
        return result
    }

    static func remuxAudioTrackToM4A(inputURL: URL, outputURL: URL) -> Bool {
        _ = networkInitOnce
        var inCtx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&inCtx, inputURL.path, nil, nil) == 0, let inputFmtCtx = inCtx else {
            return false
        }
        defer {
            var ctx: UnsafeMutablePointer<AVFormatContext>? = inputFmtCtx
            avformat_close_input(&ctx)
        }
        guard avformat_find_stream_info(inputFmtCtx, nil) >= 0 else { return false }

        var audioStreamIndex: Int32 = -1
        for i in 0 ..< Int(inputFmtCtx.pointee.nb_streams) {
            if let st = inputFmtCtx.pointee.streams[i],
               let par = st.pointee.codecpar,
               par.pointee.codec_type == AVMEDIA_TYPE_AUDIO,
               [AV_CODEC_ID_AAC, AV_CODEC_ID_ALAC].contains(par.pointee.codec_id) {
                audioStreamIndex = Int32(i)
                break
            }
        }
        guard audioStreamIndex >= 0,
              let inStream = inputFmtCtx.pointee.streams[Int(audioStreamIndex)],
              let inPar = inStream.pointee.codecpar else {
            return false
        }

        var outCtx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&outCtx, nil, "ipod", outputURL.path) >= 0,
              let outputFmtCtx = outCtx else {
            return false
        }

        var closedCleanly = false
        defer {
            if !closedCleanly {
                if let pb = outputFmtCtx.pointee.pb {
                    var pbCopy: UnsafeMutablePointer<AVIOContext>? = pb
                    avio_closep(&pbCopy)
                    outputFmtCtx.pointee.pb = nil
                }
                avformat_free_context(outputFmtCtx)
            }
        }

        guard let outStream = avformat_new_stream(outputFmtCtx, nil),
              avcodec_parameters_copy(outStream.pointee.codecpar, inPar) >= 0 else {
            return false
        }
        outStream.pointee.codecpar.pointee.codec_tag = 0

        if let flags = outputFmtCtx.pointee.oformat?.pointee.flags, (flags & AVFMT_NOFILE) == 0 {
            var pb: UnsafeMutablePointer<AVIOContext>?
            guard avio_open(&pb, outputURL.path, AVIO_FLAG_WRITE) >= 0 else { return false }
            outputFmtCtx.pointee.pb = pb
        }

        guard avformat_write_header(outputFmtCtx, nil) >= 0 else { return false }

        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        guard let pkt else { return false }
        var lastDts = [Int32: Int64]()

        while av_read_frame(inputFmtCtx, pkt) >= 0 {
            if pkt.pointee.stream_index == audioStreamIndex {
                writeRescaledPacket(
                    pkt,
                    inTimeBase: inStream.pointee.time_base,
                    outTimeBase: outStream.pointee.time_base,
                    outIndex: 0,
                    outCtx: outputFmtCtx,
                    lastDtsByOutStream: &lastDts
                )
            }
            av_packet_unref(pkt)
        }

        let trailerRet = av_write_trailer(outputFmtCtx)
        if let pb = outputFmtCtx.pointee.pb {
            var pbCopy: UnsafeMutablePointer<AVIOContext>? = pb
            avio_closep(&pbCopy)
            outputFmtCtx.pointee.pb = nil
        }
        avformat_free_context(outputFmtCtx)
        closedCleanly = true
        return trailerRet >= 0
    }

    /// Losslessly muxes a separate video stream and audio stream (e.g. adaptive HD MP4 + M4A) into one synced MP4.
    static func muxVideoAndAudioToMP4(videoURL: URL, audioURL: URL, outputURL: URL) -> Bool {
        _ = networkInitOnce
        var videoCtx: UnsafeMutablePointer<AVFormatContext>?
        var audioCtx: UnsafeMutablePointer<AVFormatContext>?

        guard avformat_open_input(&videoCtx, videoURL.path, nil, nil) == 0, let vFmtCtx = videoCtx else { return false }
        defer {
            var ctx: UnsafeMutablePointer<AVFormatContext>? = vFmtCtx
            avformat_close_input(&ctx)
        }

        guard avformat_open_input(&audioCtx, audioURL.path, nil, nil) == 0, let aFmtCtx = audioCtx else { return false }
        defer {
            var ctx: UnsafeMutablePointer<AVFormatContext>? = aFmtCtx
            avformat_close_input(&ctx)
        }

        guard avformat_find_stream_info(vFmtCtx, nil) >= 0,
              avformat_find_stream_info(aFmtCtx, nil) >= 0 else {
            return false
        }

        var inVideoIdx: Int32 = -1
        for i in 0 ..< Int(vFmtCtx.pointee.nb_streams) {
            if let st = vFmtCtx.pointee.streams[i],
               let par = st.pointee.codecpar,
               par.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
               [AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_MPEG4].contains(par.pointee.codec_id) {
                inVideoIdx = Int32(i)
                break
            }
        }

        var inAudioIdx: Int32 = -1
        for i in 0 ..< Int(aFmtCtx.pointee.nb_streams) {
            if let st = aFmtCtx.pointee.streams[i],
               let par = st.pointee.codecpar,
               par.pointee.codec_type == AVMEDIA_TYPE_AUDIO,
               [AV_CODEC_ID_AAC, AV_CODEC_ID_MP3, AV_CODEC_ID_ALAC, AV_CODEC_ID_FLAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3].contains(par.pointee.codec_id) {
                inAudioIdx = Int32(i)
                break
            }
        }

        guard inVideoIdx >= 0, inAudioIdx >= 0,
              let vInStream = vFmtCtx.pointee.streams[Int(inVideoIdx)],
              let aInStream = aFmtCtx.pointee.streams[Int(inAudioIdx)],
              let vPar = vInStream.pointee.codecpar,
              let aPar = aInStream.pointee.codecpar else {
            return false
        }

        var outCtx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&outCtx, nil, "mp4", outputURL.path) >= 0,
              let outputFmtCtx = outCtx else {
            return false
        }

        var closedCleanly = false
        defer {
            if !closedCleanly {
                if let pb = outputFmtCtx.pointee.pb {
                    var pbCopy: UnsafeMutablePointer<AVIOContext>? = pb
                    avio_closep(&pbCopy)
                    outputFmtCtx.pointee.pb = nil
                }
                avformat_free_context(outputFmtCtx)
            }
        }

        guard let outVStream = avformat_new_stream(outputFmtCtx, nil),
              let outAStream = avformat_new_stream(outputFmtCtx, nil),
              avcodec_parameters_copy(outVStream.pointee.codecpar, vPar) >= 0,
              avcodec_parameters_copy(outAStream.pointee.codecpar, aPar) >= 0 else {
            return false
        }
        outVStream.pointee.codecpar.pointee.codec_tag = vPar.pointee.codec_id == AV_CODEC_ID_HEVC
            ? CMFormatDescription.MediaSubType.hevc.rawValue.bigEndian
            : 0
        outAStream.pointee.codecpar.pointee.codec_tag = 0

        let audioFormatName = aFmtCtx.pointee.iformat?.pointee.name.flatMap { String(cString: $0) } ?? ""
        let needsADTSFilter = aPar.pointee.codec_id == AV_CODEC_ID_AAC
            && (audioFormatName.contains("mpegts") || audioFormatName.contains("hls") || audioFormatName == "aac")
        var audioBSF: UnsafeMutablePointer<AVBSFContext>?
        defer {
            if let bsf = audioBSF {
                var freePtr: UnsafeMutablePointer<AVBSFContext>? = bsf
                av_bsf_free(&freePtr)
            }
        }
        if needsADTSFilter, let filter = av_bsf_get_by_name("aac_adtstoasc") {
            var bsf: UnsafeMutablePointer<AVBSFContext>?
            if av_bsf_alloc(filter, &bsf) >= 0, let bsf {
                avcodec_parameters_copy(bsf.pointee.par_in, aPar)
                bsf.pointee.time_base_in = aInStream.pointee.time_base
                if av_bsf_init(bsf) >= 0 {
                    avcodec_parameters_copy(outAStream.pointee.codecpar, bsf.pointee.par_out)
                    audioBSF = bsf
                } else {
                    var freePtr: UnsafeMutablePointer<AVBSFContext>? = bsf
                    av_bsf_free(&freePtr)
                }
            }
        }

        if let flags = outputFmtCtx.pointee.oformat?.pointee.flags, (flags & AVFMT_NOFILE) == 0 {
            var pb: UnsafeMutablePointer<AVIOContext>?
            guard avio_open(&pb, outputURL.path, AVIO_FLAG_WRITE) >= 0 else { return false }
            outputFmtCtx.pointee.pb = pb
        }

        var muxOpts: OpaquePointer?
        av_dict_set(&muxOpts, "movflags", "+faststart", 0)
        let hdrRet = avformat_write_header(outputFmtCtx, &muxOpts)
        av_dict_free(&muxOpts)
        guard hdrRet >= 0 else { return false }

        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        guard let pkt else { return false }
        var lastDts = [Int32: Int64]()

        while av_read_frame(vFmtCtx, pkt) >= 0 {
            if pkt.pointee.stream_index == inVideoIdx {
                writeRescaledPacket(
                    pkt,
                    inTimeBase: vInStream.pointee.time_base,
                    outTimeBase: outVStream.pointee.time_base,
                    outIndex: 0,
                    outCtx: outputFmtCtx,
                    lastDtsByOutStream: &lastDts
                )
            }
            av_packet_unref(pkt)
        }

        while av_read_frame(aFmtCtx, pkt) >= 0 {
            if pkt.pointee.stream_index == inAudioIdx {
                if let audioBSF {
                    if av_bsf_send_packet(audioBSF, pkt) >= 0 {
                        av_packet_unref(pkt)
                        while av_bsf_receive_packet(audioBSF, pkt) >= 0 {
                            writeRescaledPacket(
                                pkt,
                                inTimeBase: audioBSF.pointee.time_base_out,
                                outTimeBase: outAStream.pointee.time_base,
                                outIndex: 1,
                                outCtx: outputFmtCtx,
                                lastDtsByOutStream: &lastDts
                            )
                            av_packet_unref(pkt)
                        }
                    } else {
                        av_packet_unref(pkt)
                    }
                } else {
                    writeRescaledPacket(
                        pkt,
                        inTimeBase: aInStream.pointee.time_base,
                        outTimeBase: outAStream.pointee.time_base,
                        outIndex: 1,
                        outCtx: outputFmtCtx,
                        lastDtsByOutStream: &lastDts
                    )
                    av_packet_unref(pkt)
                }
            } else {
                av_packet_unref(pkt)
            }
        }

        let trailerRet = av_write_trailer(outputFmtCtx)
        if let pb = outputFmtCtx.pointee.pb {
            var pbCopy: UnsafeMutablePointer<AVIOContext>? = pb
            avio_closep(&pbCopy)
            outputFmtCtx.pointee.pb = nil
        }
        avformat_free_context(outputFmtCtx)
        closedCleanly = true
        return trailerRet >= 0
    }
}
