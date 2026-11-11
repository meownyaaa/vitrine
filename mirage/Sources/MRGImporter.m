#import "MRGImporter.h"
#import "MRGPrefs.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSError *MRGError(NSString *text) {
    return [NSError errorWithDomain:@"Mirage" code:1 userInfo:@{NSLocalizedDescriptionKey: text}];
}

static NSURL *freshURL(NSString *ext) {
    NSString *name = [NSString stringWithFormat:@"background-%lld.%@", (long long)(NSDate.date.timeIntervalSince1970 * 1000), ext];
    return [MRGMediaDirectory() URLByAppendingPathComponent:name];
}

static UTType *typeOf(NSURL *url) {
    UTType *t = nil;
    [url getResourceValue:&t forKey:NSURLContentTypeKey error:nil];
    return t ?: [UTType typeWithFilenameExtension:url.pathExtension];
}

static CGFloat screenMaxPixels(void) {
    __block CGFloat px = 2796;
    void (^read)(void) = ^{
        CGRect b = UIScreen.mainScreen.nativeBounds;
        px = MAX(b.size.width, b.size.height);
    };
    if (NSThread.isMainThread) read(); else dispatch_sync(dispatch_get_main_queue(), read);
    return px;
}

#pragma mark - images

static NSError *importImage(NSURL *source) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)source, NULL);
    if (!src) return MRGError(@"That image could not be read.");
    // One decode at screen size, the EXIF orientation applied.
    NSDictionary *opts = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(screenMaxPixels()),
        (id)kCGImageSourceShouldCacheImmediately: @YES,
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!image) return MRGError(@"That image could not be decoded.");
    NSData *jpeg = UIImageJPEGRepresentation([UIImage imageWithCGImage:image], 0.92);
    CGImageRelease(image);
    NSURL *dst = freshURL(@"jpg");
    if (![jpeg writeToURL:dst atomically:YES]) return MRGError(@"Could not save the image.");
    MRGSetCurrentMedia(dst, MRGMediaImage);
    return nil;
}

#pragma mark - GIF -> MP4

static CMTime frameDelay(CGImageSourceRef src, size_t i) {
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, i, NULL));
    NSDictionary *gif = props[(id)kCGImagePropertyGIFDictionary];
    double d = [gif[(id)kCGImagePropertyGIFUnclampedDelayTime] doubleValue];
    if (d <= 0) d = [gif[(id)kCGImagePropertyGIFDelayTime] doubleValue];
    // Browsers treat delays under 20 ms as 100 ms; do the same.
    if (d < 0.02) d = 0.1;
    return CMTimeMakeWithSeconds(d, 600);
}

void MRGConvertGIFToMP4(NSURL *gifURL, NSURL *mp4URL, void (^done)(NSError *)) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)gifURL, NULL);
    size_t count = src ? CGImageSourceGetCount(src) : 0;
    if (!count) { if (src) CFRelease(src); done(MRGError(@"That GIF could not be read.")); return; }

    CGImageRef first = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CGFloat w = CGImageGetWidth(first), h = CGImageGetHeight(first);
    CGImageRelease(first);
    // H.264 wants even sizes; 1080 on the long side is plenty for a blurred, dimmed background.
    CGFloat scale = MIN(1.0, 1080.0 / MAX(w, h));
    size_t W = ((size_t)(w * scale)) & ~1UL, H = ((size_t)(h * scale)) & ~1UL;
    if (W < 2 || H < 2) { CFRelease(src); done(MRGError(@"That GIF is too small.")); return; }

    [NSFileManager.defaultManager removeItemAtURL:mp4URL error:nil];
    NSError *err = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:mp4URL fileType:AVFileTypeMPEG4 error:&err];
    if (!writer) { CFRelease(src); done(err); return; }
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @(W), AVVideoHeightKey: @(H),
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(W * H * 4)},
    }];
    input.expectsMediaDataInRealTime = NO;
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(W), (id)kCVPixelBufferHeightKey: @(H),
            (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        }];
    [writer addInput:input];
    if (![writer startWriting]) { CFRelease(src); done(writer.error); return; }
    [writer startSessionAtSourceTime:kCMTimeZero];

    CMTime t = kCMTimeZero;
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    for (size_t i = 0; i < count; i++) {
        @autoreleasepool {
            CGImageRef frame = CGImageSourceCreateImageAtIndex(src, i, NULL);
            CMTime delay = frameDelay(src, i);
            if (!frame) { t = CMTimeAdd(t, delay); continue; }
            while (!input.readyForMoreMediaData) [NSThread sleepForTimeInterval:0.005];
            CVPixelBufferRef pb = NULL;
            CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &pb);
            if (pb) {
                CVPixelBufferLockBaseAddress(pb, 0);
                CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), W, H, 8, CVPixelBufferGetBytesPerRow(pb), rgb,
                                                         kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
                // Transparent GIF pixels over black, the way the dim layer would show them anyway.
                CGContextSetFillColorWithColor(ctx, UIColor.blackColor.CGColor);
                CGContextFillRect(ctx, CGRectMake(0, 0, W, H));
                CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
                CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), frame);
                CGContextRelease(ctx);
                CVPixelBufferUnlockBaseAddress(pb, 0);
                [adaptor appendPixelBuffer:pb withPresentationTime:t];
                CVPixelBufferRelease(pb);
            }
            CGImageRelease(frame);
            t = CMTimeAdd(t, delay);
        }
    }
    CGColorSpaceRelease(rgb);
    CFRelease(src);
    [input markAsFinished];
    [writer endSessionAtSourceTime:t];
    [writer finishWritingWithCompletionHandler:^{
        done(writer.status == AVAssetWriterStatusCompleted ? nil : (writer.error ?: MRGError(@"The GIF could not be converted.")));
    }];
}

#pragma mark - entry point

void MRGImportFile(NSURL *source, MRGImportCompletion completion) {
    void (^finish)(NSError *) = ^(NSError *e) { dispatch_async(dispatch_get_main_queue(), ^{ completion(e); }); };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL scoped = [source startAccessingSecurityScopedResource];
        UTType *type = typeOf(source);
        if ([type conformsToType:UTTypeGIF]) {
            NSURL *dst = freshURL(@"mp4");
            MRGConvertGIFToMP4(source, dst, ^(NSError *e) {
                if (scoped) [source stopAccessingSecurityScopedResource];
                if (!e) MRGSetCurrentMedia(dst, MRGMediaVideo);
                finish(e);
            });
            return;
        }
        NSError *e = nil;
        if ([type conformsToType:UTTypeMovie] || [type conformsToType:UTTypeVideo]) {
            NSString *ext = source.pathExtension.length ? source.pathExtension.lowercaseString : @"mov";
            NSURL *dst = freshURL(ext);
            if ([NSFileManager.defaultManager copyItemAtURL:source toURL:dst error:&e]) MRGSetCurrentMedia(dst, MRGMediaVideo);
        } else if ([type conformsToType:UTTypeImage] || !type) {
            e = importImage(source);
        } else {
            e = MRGError(@"Pick an image, a GIF or a video.");
        }
        if (scoped) [source stopAccessingSecurityScopedResource];
        finish(e);
    });
}
