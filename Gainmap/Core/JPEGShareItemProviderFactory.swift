//
//  JPEGShareItemProviderFactory.swift
//  GainmapCore
//
//  File-backed share providers keep the exported JPEG bytes intact while
//  advertising the payload as an image rather than a generic file URL.
//

import Foundation
import UniformTypeIdentifiers

public enum JPEGShareItemProviderFactory {
    /// Creates one `public.jpeg` provider per URL, preserving the caller's
    /// order. The provider hands the original file to the system; it never
    /// decodes or re-encodes the image, so an embedded UltraHDR gain map stays
    /// byte-for-byte intact.
    public static func make(urls: [URL]) -> [NSItemProvider] {
        urls.map { url in
            let provider = NSItemProvider()
            provider.suggestedName = url.lastPathComponent
            provider.registerFileRepresentation(
                for: .jpeg,
                visibility: .all,
                openInPlace: false
            ) { completion in
                completion(url, false, nil)
                return nil
            }
            return provider
        }
    }
}
