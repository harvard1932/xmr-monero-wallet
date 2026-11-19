import CoreTransferable
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// The picker provides read access to one selected file. Decode it while that
/// access is valid, keeping only the QR text and never retaining the photo.
struct PaymentQRPhoto: Transferable {
    let payload: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            PaymentQRPhoto(payload: try read(file.file))
        }
    }

    static func read(_ url: URL) throws -> String {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw QRPhotoError.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2560
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw QRPhotoError.unreadable
        }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            // Some iOS environments cannot create Vision’s inference context.
            // Core Image has a separate, on-device QR detector.
            let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(options: [.useSoftwareRenderer: true]),
                                      options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            let features = detector?.features(in: CIImage(cgImage: image)) ?? []
            return try singlePayload(features.compactMap { ($0 as? CIQRCodeFeature)?.messageString })
        }
        return try singlePayload(request.results?.compactMap(\.payloadStringValue) ?? [])
    }

    static func singlePayload(_ values: [String]) throws -> String {
        let codes = Set(values.filter { !$0.isEmpty })
        guard codes.count == 1, let value = codes.first, value.utf8.count <= 4096 else {
            throw codes.count > 1 ? QRPhotoError.ambiguous : QRPhotoError.unreadable
        }
        return value
    }
}

enum QRPhotoError: LocalizedError {
    case unreadable, ambiguous
    var errorDescription: String? {
        switch self {
        case .unreadable: return WalletL10n.text("Choose a photo with a readable payment QR code.")
        case .ambiguous: return WalletL10n.text("This photo contains several QR codes. Crop it to the one you want to pay.")
        }
    }
}
