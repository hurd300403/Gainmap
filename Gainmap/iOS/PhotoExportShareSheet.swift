//
//  PhotoExportShareSheet.swift
//  Gainmap for iPhone
//
//  The system share sheet treats a JPEG file URL as a document, which exposes
//  "Save to Files" but can omit "Save Image". Supplying a decoded UIImage
//  would make the action appear, but risks re-encoding away the UltraHDR gain
//  map. This sheet adds an explicit Photos action that imports the original
//  JPEG resource bytes with PhotoKit.
//

import SwiftUI
import Photos
import UniformTypeIdentifiers
import UIKit

struct PhotoExportShareSheet: UIViewControllerRepresentable {
    typealias Completion = (
        UIActivity.ActivityType?,
        Bool,
        Error?
    ) -> Void

    let urls: [URL]
    let onCompletion: Completion?
    let onPhotoLibraryFailure: ((Error) -> Void)?

    init(
        urls: [URL],
        onCompletion: Completion? = nil,
        onPhotoLibraryFailure: ((Error) -> Void)? = nil
    ) {
        self.urls = urls
        self.onCompletion = onCompletion
        self.onPhotoLibraryFailure = onPhotoLibraryFailure
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let saveActivity = SaveImagesToPhotosActivity(urls: urls) { result in
            if case .failure(let error) = result {
                onPhotoLibraryFailure?(error)
            }
        }
        let controller = UIActivityViewController(
            activityItems: urls,
            applicationActivities: [saveActivity])
        controller.completionWithItemsHandler = {
            activityType, completed, _, error in
            onCompletion?(activityType, completed, error)
        }
        return controller
    }

    func updateUIViewController(
        _ controller: UIActivityViewController,
        context: Context
    ) {}
}

private enum PhotoLibraryExportError: LocalizedError {
    case noImages
    case missingFile(String)
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .noImages:
            return "There are no finished images to save."
        case .missingFile(let filename):
            return "\(filename) is no longer available. Export it again and retry."
        case .accessDenied:
            return "Gainmap doesn't have permission to add images to Photos. Allow Photos access in Settings and try again."
        }
    }
}

private enum PhotoLibraryExporter {
    /// Adds each JPEG as its original Photos resource. Do not decode through
    /// UIImage here: PhotoKit's file-resource path preserves the UltraHDR JPEG
    /// and its embedded gain map byte-for-byte.
    static func save(urls: [URL]) async throws -> Int {
        guard !urls.isEmpty else { throw PhotoLibraryExportError.noImages }
        for url in urls {
            var isDirectory = ObjCBool(false)
            guard url.isFileURL,
                  FileManager.default.fileExists(
                    atPath: url.path,
                    isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw PhotoLibraryExportError.missingFile(url.lastPathComponent)
            }
        }

        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw PhotoLibraryExportError.accessDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            for url in urls {
                let options = PHAssetResourceCreationOptions()
                if #available(iOS 26.0, *) {
                    options.contentType = .jpeg
                } else {
                    options.uniformTypeIdentifier = UTType.jpeg.identifier
                }
                options.originalFilename = url.lastPathComponent
                options.shouldMoveFile = false
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: url, options: options)
            }
        }
        return urls.count
    }
}

@MainActor
private final class SaveImagesToPhotosActivity: UIActivity {
    static let saveType = UIActivity.ActivityType(
        "com.legacylab.gainmap.save-images-to-photos")

    private let urls: [URL]
    private let completion: (Result<Int, Error>) -> Void

    init(urls: [URL], completion: @escaping (Result<Int, Error>) -> Void) {
        self.urls = urls
        self.completion = completion
        super.init()
    }

    override class var activityCategory: UIActivity.Category { .action }

    override var activityType: UIActivity.ActivityType? { Self.saveType }

    override var activityTitle: String? {
        urls.count == 1 ? "Save Image" : "Save \(urls.count) Images"
    }

    override var activityImage: UIImage? {
        UIImage(systemName: "square.and.arrow.down")
    }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        !urls.isEmpty
    }

    override func perform() {
        let urls = urls
        Task { @MainActor in
            do {
                let savedCount = try await PhotoLibraryExporter.save(urls: urls)
                activityDidFinish(true)
                completion(.success(savedCount))
            } catch {
                activityDidFinish(false)
                completion(.failure(error))
            }
        }
    }
}
