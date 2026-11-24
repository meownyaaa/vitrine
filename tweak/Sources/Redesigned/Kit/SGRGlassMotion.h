// Below iOS 26, the two ways iOS 26's glass moves between shapes, for the redesign's own glass (the system's does both
// itself from 26 on, and every call here does nothing there, under Reduce Motion, or without the legacy glass):
//
//   the morph    a control that gives way to another flows into it: a glass shape of the old one's place and corners
//                springs to the new one's, and the new one's own drawing comes in under it as the shape fades
//                (as the Photos app's Select flows into ⋯ and ✕ on iOS 26: about 0.2 s)
//   the bubble   a menu opened from a control leaves it as a small drop that flies to the middle of the menu,
//                growing as a circle on the way, and opens out into the menu's shape with a little overshoot: the
//                drop is the menu itself, cut to that shape, its glass and rows showing through it all the way
//                (on iOS 26 the drop is off the button 0.15 s after the tap, a circle half the menu's size 0.07 s
//                later, the menu whole by 0.35 s)
//
// The morph is drawn on views of the mod's own laid over the window, and the bubble is a mask on the menu taken off when
// it ends; what arrives is only faded in by animations added to its layer, whose model values stay as they were: nothing
// of Spotify's or UIKit's is hidden or moved, so a missed call or an early end leaves the screen as it would have been.
//
// Threading: main thread only.
#import <UIKit/UIKit.h>

// The glass the morph's shape wears: a pane made inside `host`, which is clipped to the moving shape. The caller's,
// so the shape matches what it stands for (a control's capsule).
typedef UIView *(^SGRGlassMaker)(UIView *host);

// Notes the place of `view`, a glass control that is about to go (hidden or removed), for a morph into what replaces
// it. Call it before it goes, while it is still laid out on screen. Only the latest is kept.
void SGRGlassNoteLeaving(UIView *view);

// Flows the control noted by SGRGlassNoteLeaving in the last moment into `to`, which has just been shown: `to` is laid
// out first, so the shape ends where it ends. Nothing when no control was noted lately or `to` is not on screen.
void SGRGlassMorphFromLeaving(UIView *to, SGRGlassMaker glass);

// `bar` coming in as iOS 26's toolbars do when they take another's place: each of its controls grows in from a
// little smaller, blurred into view by its opacity, one a moment after the other.
void SGRGlassBarAppear(UIView *bar);

// The bubble, from the control touched last (its frame in the window, or a drop at the touch when what was touched is
// bigger than a control) into `target`, the menu that is opening, which is itself cut to the bubble's shape by a mask
// for the length of it; `targetRadius` is its corners. Nothing when nothing was touched in the last second.
void SGRGlassBubbleOpen(UIView *target, CGFloat targetRadius);
