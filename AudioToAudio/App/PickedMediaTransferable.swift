import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { incoming in
            let destinationURL = try SecureMediaFileManager.shared.copyToManagedTemp(
                from: incoming.file,
                accessSecurityScopedResource: false
            )
            return PickedMedia(url: destinationURL)
        }
    }
}
