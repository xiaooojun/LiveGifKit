//
//  File.swift
//  
//
//  Created by 汤小军 on 2024/1/1.
//

import Foundation
import UIKit
import Photos

/// 生成的GIF
public struct GifResult {
    public let url: URL
    public let frames: [UIImage]
    public var data: Data? {
        do {
            return try Data(contentsOf: url)
        } catch {
            print("URL错误....")
            return nil
        }
    }
    
#if DEBUG
    public var totalTime: Double = 0
#endif
}

/// 生成Gif的参数Model
///
///gifFPS: gif帧率 默认 30
///watermarkInfo: 水印信息 默认为空
///data: DataSource、livePhoto和图片两种方式
///maxResolution: 图片大小 默认300
///removeImageBgColor: 是否去背景
public struct GifToolParameter {
    var data: DataSource
    var gifFPS: CGFloat
    var watermark: WatermarkConfig?
    var maxResolution: CGFloat
    var removeBg: Bool
    public enum DataSource {
        case livePhoto(livePhoto: PHLivePhoto, livePhotoFPS: CGFloat = 30)
        case images(frames: [UIImage])
    }
    public init(data: DataSource, gifFPS: CGFloat = 30, watermark: WatermarkConfig? = nil, maxResolution: CGFloat = 500, removeBg: Bool = false) {
        self.gifFPS = gifFPS
        self.watermark = watermark
        self.data = data
        self.maxResolution = maxResolution
        self.removeBg = removeBg
    }
    
    var livePhotoFPS: CGFloat {
        switch self.data {
        case .livePhoto(_, let livePhotoFPS):
            return livePhotoFPS
        case .images(_):
            return 30
        }
    }
    var gifTempDir: URL!
}