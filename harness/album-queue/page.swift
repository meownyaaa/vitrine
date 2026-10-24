struct CreativeWork { let uri: URL }
struct Template { let creativeWork: CreativeWork }
final class Page: NSObject { let template: Template; init(_ uri: String) { template = Template(creativeWork: CreativeWork(uri: URL(string: uri)!)) } }
final class WrongShape: NSObject { let creativeWork = CreativeWork(uri: URL(string: "spotify:album:4eLPsYPBmXABThSJ821sqY")!) }
let album = "spotify:album:4eLPsYPBmXABThSJ821sqY"
precondition(SGAlbumQueuePage.albumURI(Page(album)) == album)
precondition(SGAlbumQueuePage.albumURI(Page("spotify:episode:4eLPsYPBmXABThSJ821sqY")) == nil)
precondition(SGAlbumQueuePage.albumURI(WrongShape()) == nil)
precondition(SGAlbumQueuePage.albumURI(NSObject()) == nil)
print("4 album page identity checks passed")
