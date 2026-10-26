// Spotify's glyph view, from SpotifyShared.framework. It bakes its color into what it draws, so
// tintColor never reaches it and setForegroundColor: is the way in.
#import <UIKit/UIKit.h>

@interface SPTEncoreIconView : UIView
- (instancetype)initWithIcon:(id)icon;
@property (nonatomic, strong) UIColor *foregroundColor;
@property (nonatomic, strong) UIColor *activeForegroundColor;
- (void)setIsActive:(BOOL)active;
- (BOOL)isActive;
@end

@interface NSObject (SPTEncoreIcon)
- (NSString *)name;
@end
