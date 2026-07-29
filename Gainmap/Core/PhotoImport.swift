//
//  PhotoImport.swift
//  GainmapCore
//
//  P5/P6: staging picked photo data into the store's managed files so the
//  editor (and sync) can treat it like any source file. JPEG bytes pass
//  through UNTOUCHED — the content hash then matches the original file
//  everywhere it exists, so cross-device dedup works. Anything else (HEIC…)
//  transcodes to JPEG q0.95 carrying the image properties over (EXIF/GPS —
//  disclosed in the privacy copy). The full P6 import contract (tone-mapped
//  SDR in source gamut, ISO probe, memory caps) grows here.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PhotoImport {

    public enum ImportError: Error {
        case undecodable
        case writeFailed
    }

    /// True when the bytes are already a JPEG (FF D8 magic).
    public static func isJPEG(_ data: Data) -> Bool {
        data.count > 2 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xD8
    }

    /// Stage picked bytes as a JPEG file under `managedRoot`/imports/.
    /// Returns the staged file URL (a stable name derived from the content,
    /// so re-picking the same photo stages to the same path).
    @discardableResult
    public static func stage(data: Data, managedRoot: URL) throws -> URL {
        let jpegData: Data
        if isJPEG(data) {
            jpegData = data   // verbatim: keeps the content address portable
        } else {
            jpegData = try transcodeToJPEG(data)
        }
        let dir = managedRoot.appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Content-derived name: same photo -> same file -> dedup upstream.
        let name = shortHash(jpegData) + ".jpg"
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try jpegData.write(to: url, options: .atomic)
            } catch {
                throw ImportError.writeFailed
            }
        }
        return url
    }

    /// HEIC (etc.) -> JPEG q0.95, properties carried over.
    static func transcodeToJPEG(_ data: Data) throws -> Data {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ImportError.undecodable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImportError.undecodable
        }
        var destProps: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if let properties = properties as? [CFString: Any] {
            destProps.merge(properties) { current, _ in current }
        }
        CGImageDestinationAddImage(dest, image, destProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImportError.undecodable }
        return out as Data
    }

    private static func shortHash(_ data: Data) -> String {
        // Cheap stable name (not the sync content hash — that's SHA-256 in
        // ContentHash): FNV-1a over the bytes.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
