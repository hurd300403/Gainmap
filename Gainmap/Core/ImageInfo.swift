//
//  ImageInfo.swift
//  GainmapCore
//
//  Lightweight ImageIO helpers shared by the filmstrip (thumbnails) and the
//  window sizing (header-only pixel dimensions). Returns CGImage (not
//  NSImage/UIImage) so both platforms consume it directly.
//

import Foundation
import CoreGraphics
import ImageIO

public enum ImageInfo {
    /// Pixel dimensions without a full decode (reads the header only).
    public static func pixelSize(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Fast downsampled thumbnail via ImageIO (handles JPEG and float TIFF).
    public static func thumbnail(of url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
