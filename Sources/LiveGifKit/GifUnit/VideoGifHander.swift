//
//  File.swift
//  
//
//  Created by 汤小军 on 2023/12/31.
//

import Foundation
import AVFoundation
import Foundation
import UniformTypeIdentifiers
import CoreText
import UIKit

struct VideoGifHander {
    /// 创建GIF
    static func convertToGIF(videoUrl: URL, config: GifToolParameter) async throws -> GifResult {
        let asset = AVURLAsset(url: videoUrl)
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw GifError.unableToReadFile
        }
        
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            throw GifError.unableToFindTrack
        }
        
        let videoTransform = try await videoTrack.load(.preferredTransform)
        var videoSize = try await videoTrack.load(.naturalSize).applying(videoTransform)
         
        let videoWidth = abs(videoSize.width * videoTransform.a) + abs(videoSize.height * videoTransform.c)
        let videoHeight = abs(videoSize.width * videoTransform.b) + abs(videoSize.height * videoTransform.d)
        let videoFrame = CGRect(x: 0, y: 0, width: videoWidth, height: videoHeight)
        let aspectRatio = videoFrame.width / videoFrame.height
        videoSize = videoFrame.size
        let resultingSize: CGSize
        
        if videoSize.width > videoSize.height {
            let cappedWidth = round(min(config.maxResolution, videoSize.width))
            resultingSize = CGSize(width: cappedWidth, height: round(cappedWidth / aspectRatio))
        } else {
            let cappedHeight = round(min(config.maxResolution, videoSize.height))
            resultingSize = CGSize(width: round(cappedHeight * aspectRatio), height: cappedHeight)
        }
        print("视频大小: \(resultingSize)")
        
        let duration: CGFloat = try await CGFloat(asset.load(.duration).seconds)
        let nominalFrameRate = try await CGFloat(videoTrack.load(.nominalFrameRate))
        let nominalTotalFrames = Int(round(duration * nominalFrameRate))
        
        /// 计算需要舍弃的帧
        let framesToRemove = calculateFramesToRemove(desiredFrameRate: config.livePhotoFPS, nominalFrameRate: nominalFrameRate, nominalTotalFrames: nominalTotalFrames)
        let totalFrames = nominalTotalFrames - framesToRemove.count
        print("移除的帧个数； \(framesToRemove.count)  总帧的个数: \(totalFrames)")
        if totalFrames > 150 {
            throw GifError.tooManyFrames
        }
        let frameDelays = calculateFrameDelays(desiredFrameRate: config.livePhotoFPS, nominalFrameRate: nominalFrameRate, totalFrames: totalFrames)
        
        /// 视频输出设置
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: resultingSize.width,
            kCVPixelBufferHeightKey as String: resultingSize.height
        ]
        
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        reader.add(readerOutput)
        reader.startReading()
     
        var appliedFrameDelayStack = frameDelays
         
        try? LiveGifTool2.createDir(dirURL: config.gifTempDir)
        let gifUrl = config.gifTempDir.appending(component: "\(Int(Date().timeIntervalSince1970)).gif")
        
        guard let destination = CGImageDestinationCreateWithURL(gifUrl as CFURL, UTType.gif.identifier as CFString, totalFrames, nil) else {
            throw GifError.unableToCreateOutput
        }
        var currentFrameIndex = 0
        let imageOrientation = LiveGifTool2.getUIImageOrientation(transform: videoTransform)
        var sample: CMSampleBuffer? = readerOutput.copyNextSampleBuffer()
        var lastTime = CFAbsoluteTimeGetCurrent()
        
        var cgImages: [CGImage] = []
        while sample != nil {
            currentFrameIndex += 1
            if framesToRemove.contains(currentFrameIndex) {
                sample = readerOutput.copyNextSampleBuffer()
                continue
            }
 
            guard !appliedFrameDelayStack.isEmpty else { break }
            let frameDelay = appliedFrameDelayStack.removeFirst()
            autoreleasepool {
                if let newSample = sample {
                    var cgImage: CGImage? = self.cgImageFromSampleBuffer(newSample)
                    if var cgImage = cgImage  {
                        autoreleasepool {
                            var ui = UIImage(cgImage: cgImage, scale: 1.0, orientation: imageOrientation)
                            ui = ui.resize(width: config.maxResolution )
                            cgImages.append(ui.cgImage!)
                        }
                    }
                    cgImage = nil
                }
                sample = readerOutput.copyNextSampleBuffer()
            }
        }
    
        print("获取帧耗时: \(CFAbsoluteTimeGetCurrent() - lastTime)")
        lastTime = CFAbsoluteTimeGetCurrent()
        
        let fileProperties: [String: Any] = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        
        /// 开始遍历
        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFUnclampedDelayTime: 1.0/config.gifFPS],
        ]
        
        /// 移除图片背景
        let endTime2 = CFAbsoluteTimeGetCurrent()
        if config.removeBg {
            cgImages = try await LiveGifTool2.removeBg(images: cgImages)
            try Task.checkCancellation()
            print("去背景耗时: \(CFAbsoluteTimeGetCurrent() - lastTime)")
            lastTime = CFAbsoluteTimeGetCurrent()
        }

        var uiImages: [UIImage] = []
        for cgImage in cgImages {
            autoreleasepool {
                var uiImage = UIImage(cgImage: cgImage)
                if let watermark = config.watermark {
                    uiImage = uiImage.watermark(watermark: watermark)
                }
                uiImages.append(uiImage)
                CGImageDestinationAddImage(destination, uiImage.cgImage!, frameProperties as CFDictionary)
            }
        }
        
        print("合成GIF耗时: \(CFAbsoluteTimeGetCurrent() - lastTime)")
        let didCreateGIF = CGImageDestinationFinalize(destination)
        guard didCreateGIF else {
            throw GifError.unknown
        }
        return GifResult.init(url: gifUrl, frames: uiImages)
    }

    private static func cgImageFromSampleBuffer(_ buffer: CMSampleBuffer) -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)
        let bytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else {
            return nil
        }
        let image = context.makeImage()
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        return image
    }
    
    private static func calculateFramesToRemove(desiredFrameRate: CGFloat, nominalFrameRate: CGFloat, nominalTotalFrames: Int) -> [Int] {
        if desiredFrameRate < nominalFrameRate - 2 {
            let percentageOfFramesToRemove = 1.0 - (desiredFrameRate / nominalFrameRate)
            let totalFramesToRemove = Int(round(CGFloat(nominalTotalFrames) * percentageOfFramesToRemove))
            let frameRemovalInterval = CGFloat(nominalTotalFrames) / CGFloat(totalFramesToRemove)
            
            var framesToRemove: [Int] = []
            var sum: CGFloat = 0.0
            
            while sum <= CGFloat(nominalTotalFrames) {
                sum += frameRemovalInterval
                let roundedFrameToRemove = Int(round(sum))
                framesToRemove.append(roundedFrameToRemove)
            }
            
            return framesToRemove
        } else {
            return []
        }
    }
    
    static func calculateFrameDelays(desiredFrameRate: CGFloat, nominalFrameRate: CGFloat, totalFrames: Int) -> [CGFloat] {
        // The GIF spec per W3 only allows hundredths of a second, which negatively
        // impacts our precision, so implement variable length delays to adjust for
        // more precision (https://www.w3.org/Graphics/GIF/spec-gif89a.txt).
        //
        // In other words, if we'd like a 0.033 frame delay, the GIF spec would treat
        // it as 0.03, causing our GIF to be shorter/sped up, in order to get around
        // this make 70% of the frames 0.03, and 30% 0.04.
        //
        // In this section, determine the ratio of frames ceil'd to the next hundredth, versus the amount floor'd to the current hundredth.
        let desiredFrameDelay: CGFloat = 1.0 / min(desiredFrameRate, nominalFrameRate)
        let flooredHundredth: CGFloat = floor(desiredFrameDelay * 100.0) / 100.0 // AKA "slow frame delay"
        let remainder = desiredFrameDelay - flooredHundredth
        let nextHundredth = flooredHundredth + 0.01 // AKA "fast frame delay"
        let percentageOfNextHundredth = remainder / 0.01
        let percentageOfCurrentHundredth = 1.0 - percentageOfNextHundredth
        
        let totalSlowFrames = Int(round(CGFloat(totalFrames) * percentageOfCurrentHundredth))
        
        // Now determine how they should be distributed, we obviously don't just
        // want all the longer ones at the end (would make first portion feel fast,
        // second part feel slow), so evenly distribute them along the GIF timeline.
        //
        // Determine the spacing in relation to slow frames, so for instance if it's 1.7, the round(1.7) = 2nd frame would be slow, then the round(1.7 * 2) = 3rd frame would be slow, etc.
        let spacingInterval = CGFloat(totalFrames) / CGFloat(totalSlowFrames)
        
        // Initialize it to start with all the fast frame delays, and then we'll identify which ones will be slow and modify them in the loop to follow
        var frameDelays: [CGFloat] = [CGFloat](repeating: nextHundredth, count: totalFrames)
        var sum: CGFloat = 0.0
        
        while sum <= CGFloat(totalFrames) {
            sum += spacingInterval
            let slowFrame = Int(round(sum))
            
            // Confusingly (for us), frames are indexed from 1, while the array in Swift is indexed from 0
            if slowFrame - 1 < totalFrames {
                frameDelays[slowFrame - 1] = flooredHundredth
            }
        }
        return frameDelays
    }
}