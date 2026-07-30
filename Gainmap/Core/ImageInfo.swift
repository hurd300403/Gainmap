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

    /// Display-oriented pixel dimensions without decoding the image.
    ///
    /// `pixelSize(of:)` deliberately reports the encoded raster dimensions.
    /// This companion applies only the EXIF orientation's axis swap, which is
    /// useful for sizing UI around the image as a viewer will present it.
    public static func displayPixelSize(of url: URL) -> CGSize? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let src = CGImageSourceCreateWithURL(
            url as CFURL, options as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(
                src, 0, options as CFDictionary) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0
        else { return nil }

        let orientation =
            (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
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
