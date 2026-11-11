// Turns a picked file into Mirage's current background, in Documents/Mirage/Backgrounds:
// images are downscaled to the screen and stored as JPEG (PNG, JPG, HEIC, anything ImageIO reads),
// GIFs become a looping H.264 MP4 (cheaper on the battery than decoding a GIF every frame),
// MP4/MOV are copied as they are (their audio is never played: MRGVideoEngine plays the video track only).
#import <UIKit/UIKit.h>

typedef void (^MRGImportCompletion)(NSError *error);

void MRGImportFile(NSURL *source, MRGImportCompletion completion);   // completion on the main queue
// Exposed for tests: GIF -> MP4.
void MRGConvertGIFToMP4(NSURL *gif, NSURL *mp4, void (^done)(NSError *error));
