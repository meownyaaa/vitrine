// SongDNA redesign, iOS < 26: the Data Sources card of the Report sheet on the sheet's glass. The sheet is glass
// already (SGRGlassSheetChrome), but its card (SongDNA_ReportPageImpl.DataSourcesCardView, #2A2A2A, r=8,
// id=song-dna-report-data-sources-card) is drawn as an opaque grey, and being a rounded card narrower than the
// sheet the chrome leaves it as it is. It is painted the translucent white the device picker's cards have
// (SGRSheetCardFill) instead: a slight lightening of the block against the sheet.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Pages/Pages.h"

static void lighten(UIView *card) {
    if (card.bounds.size.width < 1) return;
    CGColorRef fill = SGRSheetCardFill();
    CGColorRef now = card.layer.backgroundColor;
    if (now && CGColorEqualToColor(now, fill)) return;
    card.layer.backgroundColor = fill;
}

%group SGRSongDNAReport
%hook SGRDataSourcesCard
- (void)setBackgroundColor:(UIColor *)color {
    if (color && SGRIsSheetSurface(color.CGColor)) color = [UIColor colorWithCGColor:SGRSheetCardFill()];
    %orig(color);
}

- (void)layoutSubviews {
    %orig;
    lighten((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) lighten((UIView *)self);
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGBelowiOS26()) return;
    Class card = SGRSwiftClass(@"SongDNA_ReportPageImpl", @"DataSourcesCardView");
    if (!card) {
        SGLog(@"class SongDNA_ReportPageImpl.DataSourcesCardView not found, the Data Sources card keeps Spotify's grey");
        return;
    }
    %init(SGRSongDNAReport, SGRDataSourcesCard = card);
}
