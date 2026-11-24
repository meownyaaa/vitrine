// Now playing redesign: glass for the queue sheet and its controls. Clear and Edit (QueueHeaderView's
// PillButton) and the edit-mode toolbar's Move up / Remove / Clear selection are flat 10%-white capsules,
// like the playlist's sort/find toolbar, and so is the Reshuffle capsule over the list. The sheet itself (id=sheet-view, as in
// the ⋯ context menu) gets its pane from SGRGlassSheetChrome, the call Playlist/PlaylistMenu.x makes too. That
// call also clears the grey (#1F1F1F) of the queue's table and rows, and the Kit's repaint hook keeps it
// clear.
//
// Reshuffle (and any other move of rows) leaves the rows that changed place painted #1F1F1F again, the cell and the
// stack inside it (every played-through QueueCell and its TrackRowQueue.Cell stack, visible and hidden, still grey with
// the glass clear around them) until a scroll lays the rows out anew. The sheet-wide hooks of SGRRepaint.x did not
// catch that paint, and a row that only changes place gets no layout pass of its own, so nothing cleared it. The cells
// clear their own grey now, as it is painted, as they are selected, attached or laid out, and the table's reloads and
// moves run a few passes over its rows.
//
// The queue is built and painted after its first layout pass, so a chrome pass that runs only from
// viewDidLayoutSubviews missed the bar of Shuffle / Repeat / Timer and the edit toolbar (both #1F1F1F)
// until a drag of the sheet laid it out again. It runs from the view's appearance and from the next turns of the run loop
// as well, and the two bars clear their own paint whenever it is laid down.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

// NowPlaying_ECMKit.QueueHeader.UI.Private.PillButton, as NSStringFromClass prints it.
static NSString *const kPillButtonClass = @"_TtCOOO17NowPlaying_ECMKit11QueueHeader2UI7Private10PillButton";

static char kCloseGlassKey, kCloseKey, kPillGlassKey, kChipGlassKey, kReshuffleKey, kReshuffleGlassKey, kPlayKey;
static char kMoveUpKey, kRemoveKey, kClearSelectionKey;

// Queue_ViewImpl.QueueCell, as NSStringFromClass prints it.
static NSString *const kQueueCellClass = @"_TtC14Queue_ViewImpl9QueueCell";

// The grey of one row of the queue: the cell and every band inside it nearly as wide as the cell (the stack the element
// framework wraps the row in). Narrow ones stay (the cover's placeholder square, a badge): they are their own paint.
static void clearRowPaint(UIView *view, CGFloat wide, int depth) {
    if (!view || depth > 12 || wide < 1) return;   // wide 0: the cell has no size yet; the pass that gives it one does it
    if (!SGKeepsColor(view) && view.bounds.size.width >= wide) {
        CGColorRef paint = view.layer.backgroundColor;
        if (paint && SGRIsSheetSurface(paint)) view.backgroundColor = UIColor.clearColor;
        // An opaque view with no fill is drawn over black (SGRGlass.m's clearListPaint).
        if (view.opaque || view.layer.opaque) {
            view.opaque = NO;
            view.layer.opaque = NO;
        }
    }
    for (UIView *sub in view.subviews) clearRowPaint(sub, wide, depth + 1);
}

static void clearCell(UIView *cell) {
    clearRowPaint(cell, cell.bounds.size.width * SGRSheetBandShare, 0);
}

// Every QueueCell under `scope`, hidden ones (the copies a move leaves in the table) included.
static void clearQueueRows(UIView *scope) {
    Class cellClass = NSClassFromString(kQueueCellClass);
    if (!scope || !cellClass) return;
    SGForEachView(scope, ^(UIView *view) {
        if ([view isKindOfClass:cellClass]) clearCell(view);
    });
}

// Clear and Edit: wherever QueueHeaderView has put them this pass.
static void glassPills(UIView *root) {
    SGForEachView(root, ^(UIView *view) {
        if ([NSStringFromClass(view.class) isEqualToString:kPillButtonClass]) SGRGlassFlatBox(view, &kPillGlassKey, NO);
    });
}

// The edit-mode toolbar's three chips: each button's own wrapping capsule, found by the button's
// identifier and glassed one superview up.
static void glassChip(UIView *root, NSString *buttonIdentifier, const void *cacheKey) {
    UIView *button = SGRFindByIdentifier(root, buttonIdentifier, cacheKey);
    if (button && button.superview) SGRGlassFlatBox(button.superview, &kChipGlassKey, NO);
}

// The edit mode's close cross (id=queue-close-edit-button, top right, 32pt): a glass circle like the other round controls.
static void glassClose(UIView *root) {
    UIView *button = SGRFindByIdentifier(root, @"queue-close-edit-button", &kCloseKey);
    if (button && button.bounds.size.width >= 1) SGRGlassInside(button, &kCloseGlassKey, button.bounds.size.width);
}

// The Reshuffle capsule (Encore Primary button, id=reshuffle-button) that floats over the list once the
// queue has been played through: it is the sheet's one primary action, so its glass carries the white film
// (prominent) and reads a step brighter than Clear and Edit instead of vanishing into the sheet.
//
// Encore draws the button's fill as a shape layer the size of the button in the plain view over the glass, not as a
// background colour (SGLegacyGlassView first, then a 89.5x32 UIView with a CAShapeLayer), so the capsule still read
// as Spotify's flat black one with the glass under it. That layer is hidden, not given a clear fill, since Encore
// sets the fill again as the button is pressed and let go.
static void glassReshuffle(UIView *root) {
    UIView *button = SGRFindByIdentifier(root, @"reshuffle-button", &kReshuffleKey);
    UIView *glass = SGRGlassFlatBox(button, &kReshuffleGlassKey, YES);
    if (!glass) return;
    CGSize size = button.bounds.size;
    for (UIView *sub in button.subviews) {
        if (sub == glass || !CGSizeEqualToSize(sub.bounds.size, size)) continue;
        for (CALayer *layer in sub.layer.sublayers) {
            if ([layer isKindOfClass:CAShapeLayer.class] && CGSizeEqualToSize(layer.bounds.size, size) && !layer.hidden) layer.hidden = YES;
        }
    }
}

// The Now playing row's play / pause button (id=header-play-button): Spotify draws a dark grey shadow under
// it that runs down over the glass. Taken off its layers, and again whenever Spotify lays it out.
static void flattenPlay(UIView *button) {
    if (button.layer.shadowOpacity > 0) button.layer.shadowOpacity = 0;
    for (UIView *v in button.subviews) flattenPlay(v);
}

static void chrome(UIViewController *controller) {
    UIView *root = controller.viewIfLoaded;
    if (!root) return;
    SGRGlassSheetChrome(root);
    glassPills(root);
    glassReshuffle(root);
    glassClose(root);
    UIView *play = SGRFindByIdentifier(root, @"header-play-button", &kPlayKey);
    if (play) flattenPlay(play);
    glassChip(root, @"queue-edit-toolbar-move-up", &kMoveUpKey);
    glassChip(root, @"queue-edit-toolbar-remove", &kRemoveKey);
    glassChip(root, @"queue-edit-toolbar-clear-selection", &kClearSelectionKey);
    clearQueueRows(root);
}

// The rows themselves. Spotify paints the cell and its stack again as a row is configured, moved, picked up or let go,
// from layout passes that a plain change of place does not run.
%hook _TtC14Queue_ViewImpl9QueueCell
- (void)layoutSubviews {
    %orig;
    clearCell((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) clearCell((UIView *)self);
}

- (void)didMoveToSuperview {
    %orig;
    if (((UIView *)self).superview) clearCell((UIView *)self);
}

- (void)setBackgroundColor:(UIColor *)color {
    if (color && SGRIsSheetSurface(color.CGColor)) color = UIColor.clearColor;
    %orig(color);
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    %orig;
    clearCell((UIView *)self);
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    clearCell((UIView *)self);
}

- (void)addSubview:(UIView *)view {
    %orig;
    clearRowPaint(view, ((UIView *)self).bounds.size.width * SGRSheetBandShare, 1);
}
%end

// Reshuffle reloads the list or moves its rows, and Spotify paints the rows that changed place on its own turns of the
// run loop after that. A few passes over the table's rows follow each reload and move, as the sheet's own chrome gets
// after it appears.
static void clearTableLater(UITableView *table) {
    UIView *root = sgr_sheetChromeRoot;
    if (!root || !SGIsInside(table, root)) return;
    SGRRepeatViewPass(table, @[@0.0, @0.1, @0.3, @0.7], ^(UIView *v) { clearQueueRows((UITableView *)v); });
}

%hook UITableView
- (void)reloadData {
    %orig;
    clearTableLater((UITableView *)self);
}

- (void)endUpdates {
    %orig;
    clearTableLater((UITableView *)self);
}

- (void)moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    %orig;
    clearTableLater((UITableView *)self);
}

- (void)performBatchUpdates:(void (^)(void))updates completion:(void (^)(BOOL))completion {
    %orig;
    clearTableLater((UITableView *)self);
}
%end

// The two bars under the list: Queue_ViewImpl.SessionModifiersView and EditModeToolbarView, painted
// #1F1F1F by Spotify when they are made and each time their content changes.
static void clearBar(UIView *bar) {
    if (SGRIsSheetSurface(bar.layer.backgroundColor)) bar.backgroundColor = UIColor.clearColor;
}

// Spotify sets the shadow as the button's state changes, play to pause included, which no pass of the sheet follows.
%hook _TtC28EncoreConsumerMobile_BaseKit14PlayButtonView
- (void)layoutSubviews {
    %orig;
    UIView *button = (UIView *)self;
    if (![button.accessibilityIdentifier isEqualToString:@"header-play-button"]) return;
    for (UIResponder *r = button; r; r = r.nextResponder) {
        if (![r isKindOfClass:UIViewController.class]) continue;
        if ([NSStringFromClass(r.class) containsString:@"Queue_ViewImpl"]) flattenPlay(button);
        return;
    }
}
%end

#pragma mark - edit mode, flowing

// Edit gives way to the close cross as the queue goes into edit mode, and the cross to Edit as it comes out, the way
// the Photos app's Select flows into its ⋯ and ✕: Spotify hides the one and shows the other in the same pass
// (out/tree-queue.txt: the Edit pill at 62x32, the cross at 32x32 hidden beside it), and the glass of the one flows
// into the other (Kit/SGRGlassMotion.h). The bar under the list, Shuffle / Repeat / Timer or the edit toolbar, comes
// in control by control as the other goes.
static char kMorphGlassKey;

static UIView *morphGlass(UIView *host) {
    UIView *glass = SGGlassFor(host, &kMorphGlassKey);
    glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    return glass;
}

// Before Spotify's setHidden: notes the control that goes. After it: flows the noted one into the control that came.
static void editControlWillHide(UIView *control, BOOL hidden) {
    if (hidden && !control.hidden) SGRGlassNoteLeaving(control);
}

static void editControlDidShow(UIView *control, BOOL was, BOOL hidden) {
    if (hidden || !was || !sgr_sheetChromeRoot || !SGIsInside(control, sgr_sheetChromeRoot)) return;
    SGRGlassMorphFromLeaving(control, ^UIView *(UIView *host) { return morphGlass(host); });
}

%hook _TtCOOO17NowPlaying_ECMKit11QueueHeader2UI7Private10PillButton
- (void)setHidden:(BOOL)hidden {
    UIView *pill = (UIView *)self;
    BOOL was = pill.hidden;
    editControlWillHide(pill, hidden);
    %orig;
    editControlDidShow(pill, was, hidden);
}
%end

%hook _TtCCE16Encore_ButtonKitO16EncoreFoundation6Encore6Button8Tertiary
- (void)setHidden:(BOOL)hidden {
    UIView *button = (UIView *)self;
    BOOL close = [button.accessibilityIdentifier isEqualToString:@"queue-close-edit-button"];
    BOOL was = button.hidden;
    if (close) editControlWillHide(button, hidden);
    %orig;
    if (close) editControlDidShow(button, was, hidden);
}
%end

static void barHidden(UIView *bar, BOOL hidden) {
    if (!hidden && sgr_sheetChromeRoot && SGIsInside(bar, sgr_sheetChromeRoot)) SGRGlassBarAppear(bar);
}

%hook _TtC14Queue_ViewImpl19EditModeToolbarView
- (void)setHidden:(BOOL)hidden {
    BOOL was = ((UIView *)self).hidden;
    %orig;
    if (was && !hidden) barHidden((UIView *)self, hidden);
}
%end

%hook _TtC14Queue_ViewImpl20SessionModifiersView
- (void)setHidden:(BOOL)hidden {
    BOOL was = ((UIView *)self).hidden;
    %orig;
    if (was && !hidden) barHidden((UIView *)self, hidden);
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    %init;
    SGRPassView(NSClassFromString(@"_TtC14Queue_ViewImpl19EditModeToolbarView"), ^(UIView *v) { clearBar(v); });
    SGRPassView(NSClassFromString(@"_TtC14Queue_ViewImpl20SessionModifiersView"), ^(UIView *v) { clearBar(v); });
    SGRPassControllersNamed(@[@"_TtC14Queue_ViewImpl19QueueViewController"], ^(UIViewController *c) { chrome(c); });
    SGRequireClasses(@[@"_TtC28EncoreConsumerMobile_BaseKit14PlayButtonView", kQueueCellClass]);
}
