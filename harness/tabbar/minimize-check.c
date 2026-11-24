// SGRMinimizeStep on the Mac: cc -I../../tweak/Sources/Redesigned/Navbar minimize-check.c -o build/minimize-check && build/minimize-check
#include <assert.h>
#include <stdio.h>
#include "MinimizeStep.h"

// A page from -100 (its top, under a 100 pt header inset) to 2000.
static bool step(SGRMinimizeTrack *t, CGFloat offset) { return SGRMinimizeStep(t, offset, -100, 2000); }

int main(void) {
    SGRMinimizeTrack t = {-100, false};
    assert(!step(&t, -90));          // a little way down: a finger resting
    assert(!step(&t, -77));
    assert(step(&t, -76));           // 24 down from the top: minimized
    assert(step(&t, 600));           // further down
    assert(step(&t, 590));           // a jitter back up is not a scroll up
    assert(!step(&t, 576));          // 24 back up from the lowest point, mid-list: expanded
    assert(!step(&t, 560));          // still going up
    assert(step(&t, 584));           // down again from where it turned
    assert(step(&t, 2000));          // the foot
    assert(step(&t, 2080));          // pulled past it
    assert(step(&t, 2000));          // springing back is not a scroll up
    assert(!step(&t, -100));         // the top always expands
    assert(!step(&t, -140));         // pulled past the top

    SGRMinimizeTrack s = {0, false}; // a page with almost nothing to scroll
    assert(!SGRMinimizeStep(&s, 80, 0, 100));
    s.minimized = true;              // and one that cannot scroll leaves a minimized bar minimized
    assert(SGRMinimizeStep(&s, 0, 0, 100));
    // The capsule bar (iOS < 26): minimized stays minimized while scrolling up, and the top brings it back.
    SGRMinimizeTrack h = {-100, false};
    assert(SGRMinimizeStepEx(&h, -70, -100, 2000, false));   // minimized going down
    assert(SGRMinimizeStepEx(&h, 800, -100, 2000, false));
    assert(SGRMinimizeStepEx(&h, 700, -100, 2000, false));   // up 100: still minimized
    assert(SGRMinimizeStepEx(&h, 300, -100, 2000, false));
    assert(SGRMinimizeStepEx(&h, -60, -100, 2000, false));   // near the top, not at it
    assert(!SGRMinimizeStepEx(&h, -100, -100, 2000, false)); // the top
    assert(SGRMinimizeStepEx(&h, -60, -100, 2000, false));   // and down again minimizes
    puts("minimize-check: ok");
    return 0;
}
