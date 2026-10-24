import Foundation

// 9.1.90's CreativeWorkPageViewController keeps its identity here. Swift reflection reads the
// named fields without depending on offsets or importing Spotify's modules. A changed shape yields nil.
@objc(SGAlbumQueuePage)
public final class SGAlbumQueuePage: NSObject {
    @objc public static func albumURI(_ controller: AnyObject) -> String? {
        var value: Any = controller
        for field in ["template", "creativeWork", "uri"] {
            guard let child = Mirror(reflecting: value).children.first(where: { $0.label == field }) else { return nil }
            value = child.value
        }
        guard let url = value as? URL, url.absoluteString.hasPrefix("spotify:album:") else { return nil }
        return url.absoluteString
    }
}
