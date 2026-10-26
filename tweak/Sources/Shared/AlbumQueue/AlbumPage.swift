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

@objc(SGEntityPage)
public final class SGEntityPage: NSObject {
    @objc public static func entityURI(_ controller: AnyObject) -> String? {
        if let album = SGAlbumQueuePage.albumURI(controller) { return album }
        return playlistURI(controller)
    }

    @objc public static func playlistURI(_ controller: AnyObject) -> String? {
        func search(_ val: Any, depth: Int) -> String? {
            if depth > 4 { return nil }
            let mirror = Mirror(reflecting: val)
            for child in mirror.children {
                if let str = child.value as? String, str.hasPrefix("spotify:playlist:") {
                    return str
                }
                if let url = child.value as? URL, url.absoluteString.hasPrefix("spotify:playlist:") {
                    return url.absoluteString
                }
                if let res = search(child.value, depth: depth + 1) {
                    return res
                }
            }
            return nil
        }
        return search(controller, depth: 0)
    }
}
