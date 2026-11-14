// The clip view of Vitrine Addon's lock screen Canvas (MediaRemoteUICanvas.x): the song's clip fitted whole to the
// view's width, the bands above and below it in its first frame's edge colours and its own top and bottom fading into
// them, so no edge of it shows, as a redesigned album's page runs on in its cover's colour. It plays with no AVPlayer,
// which takes an audio session the system counts as playback and paused Spotify for: its frames are read from the file
// (AVAssetReader, the video track alone) and handed to an AVSampleBufferDisplayLayer on a timebase of its own, looped,
// held still while the song is paused.
//
// Threading: main thread; the frames are read on a queue of its own.
#import <UIKit/UIKit.h>

@interface SGVLockClip : UIView
// The clip to play from its start, or nil for none; the same file again is let be.
- (void)playClip:(NSURL *)clip;
// Playing, or held on its frame.
- (void)setPlaying:(BOOL)playing;
// The song's still cover, drawn the same way, square, under the clip: shown alone with no clip, and until its first frame.
- (void)showCover:(UIImage *)cover;
// Whether anything is drawn: a clip or a cover.
@property (nonatomic, readonly) BOOL hasContent;
// Where the clip, or else the cover, is drawn, in the view's own space: the large cover itself, a tap on which closes it.
@property (nonatomic, readonly) CGRect drawnFrame;
// While the screen is dark nothing is read or decoded; lit again, the clip starts over on a new display layer, as the
// one before can come back unable to decode, leaving bands with no picture between them.
- (void)setSuspended:(BOOL)suspended;
@end
