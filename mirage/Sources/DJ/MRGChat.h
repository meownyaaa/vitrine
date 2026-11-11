// The DJ chat: a conversation with the user's AI provider that can act through tools (function calling, each
// provider's own format, MRGAIChatTools): search Spotify, play or queue tracks, start a DJ set, answer questions
// from the on-phone listening history (MRGHistory), and change playlists through Spotify's playlist engine
// (MRGPlaylists). Deleting a playlist only ever happens after the listener taps Delete on the card in the chat.
#import <Foundation/Foundation.h>

extern NSString *const MRGChatChangedNotification;   // main queue

@interface MRGChatItem : NSObject
@property (nonatomic, copy) NSString *kind;     // "user", "dj", "card", "note", "error"
@property (nonatomic, copy) NSString *text;
// Cards: type "first_played" {artist, image, date, firstTrack, firstURI, plays, minutes, source}
//              "tracks"       {title, tracks: [{uri, title, artist, image}]}
//              "playlist"     {name, uri, detail}
//              "confirm_delete" {name, uri, state: pending|deleted|cancelled|failed, detail}
//              "list"         {title, rows: [{title, detail}]}
@property (nonatomic, copy) NSDictionary *card;
@end

@interface MRGChat : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) NSArray<MRGChatItem *> *items;
@property (nonatomic, readonly, getter=isBusy) BOOL busy;
@property (nonatomic, readonly, copy) NSString *busyText;
- (void)send:(NSString *)text;
// A question answered from the DJ sheet's vibe box: shown (and remembered) in the chat too, with its card.
- (void)noteQuestion:(NSString *)question answer:(NSString *)answer card:(NSDictionary *)card;
- (void)confirmDelete:(MRGChatItem *)card;
- (void)cancelDelete:(MRGChatItem *)card;
- (void)playTrack:(NSDictionary *)track;      // from a card's play button
- (void)reset;
// Runs one of the chat's tools directly (the DJ sheet uses play_context for playlists and albums). Main queue.
- (void)runTool:(NSString *)name args:(NSDictionary *)args done:(void (^)(id result))done;
@end
