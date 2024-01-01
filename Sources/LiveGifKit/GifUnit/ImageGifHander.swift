//
//  File.swift
//  
//
//  Created by 汤小军 on 2023/12/31.
//

import Foundation
import UIKit
import UniformTypeIdentifiers

struct ImageGifHander {
    static public func createGif(uiImages: [UIImage], config: GifToolParameter) async throws -> GifResult {
        if uiImages.isEmpty {
            throw GifError.gifResultNil
        }
        try? LiveGifTool2.createDir(dirURL: config.gifTempDir)
        let gifFileName = "\(Int(Date().timeIntervalSince1970)).gif"
        let gifURL = config.gifTempDir.appending(path: gifFileName)
      
        guard let destination = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, uiImages.count, nil) else {
            throw GifError.unableToCreateOutput
        }
        
        let fileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]
        ]
        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFUnclampedDelayTime: 1.0/config.gifFPS],
            kCGImagePropertyOrientation as String: LiveGifTool2.getCGImageOrientation(imageOrientation: uiImages.first?.imageOrientation ?? .right).rawValue
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        var cgImages = uiImages.map({ $0.cgImage! })
        if config.removeBg {
            cgImages = try await LiveGifTool2.removeBg(images: cgImages)
            try Task.checkCancellation()
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
        
        let didCreateGIF = CGImageDestinationFinalize(destination)
        guard didCreateGIF else {
            throw GifError.unknown
        }
        return GifResult.init(url: gifURL, frames: uiImages)
    }

}
