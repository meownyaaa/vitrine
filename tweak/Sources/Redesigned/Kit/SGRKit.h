// The Redesign Kit: what every part of the redesign (Redesigned/<Part>/) builds on, so the screens share
// one look and nothing is hand-rolled per screen. A screen imports this and Core/SGCore.h.
//
//     SGRedesign.h   Redesigned UI, the one switch, and the flags the redesigned screens force
//     SGRTokens.h    colors, type, spacing, radii, motion, the accessibility settings
//     SGRPalette.h   the artwork's edge color, the field color and the pre-blurred bitmaps
//     SGRField.h     the artwork field behind a page
//     SGRFlow.h      the player's moving field of the artwork's colors
//     SGRGlass.h     glass inside Spotify's round controls
//     SGRGlassMotion.h  iOS 26's glass flowing from one control into the next (iOS < 26)
//     SGRGlyph.h     bare glyph overlays and glyph buttons
//     SGRActionRow.h the Play capsule and the stand-in button of a page's action row
//     SGRDownload.h  Spotify's download state, read, and the glyph drawn for it
//     SGRHeaderInfo.h a page header's title, creator, length, row and description, the Music app's
//     SGRChips.h     Encore's filter chips on glass (Liked Songs, Recents)
//     SGRStretchHero.h a page header's picture, dissolving into the field and stretching on a pull (album, artist)
//     SGRRestyle.h   keeping Spotify's views restyled: suppress, digits, lookups, shadows, firing
//                    controls, taking a list cell's paint off the field, a hard top edge (SGREdgeEffect.x)
//     SGRBridges.h   player state, now playing artwork, the player's open and close
//     SGRAlertScreen.h  the system alert and action sheet as Telegram draws them (iOS < 26; SGRAlertHook.x swaps them in)
//     SGRPass.h      passes over Spotify's controllers and views, repeated as they settle
//     SGRRepaint.h   the areas the redesign keeps transparent when Spotify repaints them
//     SGRAccent.h    the redesign's accent color; its AMOLED black is SGRAmoled.x, always on
//     SGRDrawnText.h the text and the white of a SwiftUI card put on glass (the toasts, the tooltips)
//     Settings/SGMarquee.h  a title that glides when it is too long, every layer's, imported here for the screens
//
// Every hook file of the redesign starts its %ctor with `if (!SGRedesignedUI()) return;` and every one
// of Native/ with `if (!SGNativeUI()) return;` (Core/SGUIMode.h), so the two looks never run together.
#import "SGRedesign.h"
#import "SGRTokens.h"
#import "SGRPalette.h"
#import "SGRField.h"
#import "SGRFlow.h"
#import "SGRGlass.h"
#import "SGRGlassMotion.h"
#import "SGRGlyph.h"
#import "SGRActionRow.h"
#import "SGRDownload.h"
#import "SGRHeaderInfo.h"
#import "SGRStretchHero.h"
#import "SGRRestyle.h"
#import "SGRChips.h"
#import "SGRBridges.h"
#import "SGRPass.h"
#import "SGRRepaint.h"
#import "SGRAccent.h"
#import "SGRDrawnText.h"
#import "Settings/SGMarquee.h"
