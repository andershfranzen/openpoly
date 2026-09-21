#import "CGVirtualDisplayPrivate.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include "p21-dl3.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

@interface P21FrameSink : NSObject <SCStreamOutput>
- (instancetype)initWithCounter:(_Atomic unsigned *)counter;
@end

@implementation P21FrameSink {
    _Atomic unsigned *_counter;
}
- (instancetype)initWithCounter:(_Atomic unsigned *)counter {
    if ((self = [super init])) _counter = counter;
    return self;
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample
        ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
    if (!pixels) return;
    unsigned count = atomic_fetch_add_explicit(_counter, 1, memory_order_relaxed) + 1;
    if (count == 1) {
        printf("first frame=%zux%zu\n", CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels));
        fflush(stdout);
    }
}
@end

static void usage(const char *name) {
    fprintf(stderr, "usage: %s [--probe | seconds]\n", name);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        int seconds = 5;
        int probeOnly = argc == 2 && strcmp(argv[1], "--probe") == 0;
        if (argc > 2) { usage(argv[0]); return 2; }
        if (argc == 2 && !probeOnly) {
            char *end = NULL;
            long value = strtol(argv[1], &end, 10);
            if (!end || *end || value < 1 || value > 3600) { usage(argv[0]); return 2; }
            seconds = (int)value;
        }

        p21_dl3_identity dl3 = {0};
        char probeError[256];
        if (p21_dl3_probe(&dl3, probeError, sizeof(probeError))) {
            fprintf(stderr, "P21 DL3 probe failed: %s\n", probeError);
            return 1;
        }
        printf("p21-dl3 usb=%x.%02x device=%x.%02x interface=%u out=0x%02x in=0x%02x "
               "packet=%u firmware=%u.%u.%u platform=%s\n",
               dl3.bcd_usb >> 8, dl3.bcd_usb & 0xff,
               dl3.bcd_device >> 8, dl3.bcd_device & 0xff,
               dl3.interface_number, dl3.bulk_out, dl3.bulk_in,
               dl3.max_packet_size, dl3.firmware_major, dl3.firmware_minor,
               dl3.firmware_patch, dl3.platform);
        if (probeOnly) return 0;

        CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
        descriptor.name = @"Poly Studio P21 (open host)";
        descriptor.maxPixelsWide = 1920;
        descriptor.maxPixelsHigh = 1080;
        descriptor.sizeInMillimeters = CGSizeMake(527, 296);
        descriptor.vendorID = 0x4199; // PLY EDID manufacturer code used by the P21.
        descriptor.productID = 1;
        descriptor.serialNum = 0x503231;
        descriptor.queue = dispatch_get_main_queue();
        descriptor.terminationHandler = ^(id owner, CGVirtualDisplay *display) {
            (void)owner; (void)display;
            fputs("virtual display terminated by macOS\n", stderr);
        };

        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        if (!display) { fputs("cannot create CGVirtualDisplay\n", stderr); return 1; }

        CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
        settings.hiDPI = 0;
        settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:1920
                                                                  height:1080
                                                             refreshRate:60.0]];
        if (![display applySettings:settings]) {
            fputs("cannot apply 1920x1080@60 virtual-display mode\n", stderr);
            return 1;
        }

        _Atomic unsigned *frames = calloc(1, sizeof(*frames));
        if (!frames) return 1;
        __block SCDisplay *target = nil;
        __block NSError *contentError = nil;
        NSDate *discoveryDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!target && [discoveryDeadline timeIntervalSinceNow] > 0) {
            dispatch_semaphore_t ready = dispatch_semaphore_create(0);
            [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                                      onScreenWindowsOnly:NO
                                                       completionHandler:^(SCShareableContent *content, NSError *error) {
                contentError = error;
                for (SCDisplay *candidate in content.displays) {
                    if (candidate.displayID == display.displayID) { target = candidate; break; }
                }
                dispatch_semaphore_signal(ready);
            }];
            NSTimeInterval remaining = [discoveryDeadline timeIntervalSinceNow];
            long timedOut = dispatch_semaphore_wait(
                ready, dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(MAX(remaining, 0.0) * NSEC_PER_SEC)));
            if (timedOut) {
                fputs("ScreenCaptureKit display discovery timed out\n", stderr);
                free(frames); return 1;
            }
            if (!target) [NSThread sleepForTimeInterval:0.1];
        }
        if (!target) {
            fprintf(stderr, "virtual display is unavailable to ScreenCaptureKit: %s\n",
                    contentError.localizedDescription.UTF8String ?: "grant Screen Recording permission");
            free(frames); return 1;
        }

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:target excludingWindows:@[]];
        SCStreamConfiguration *configuration = [SCStreamConfiguration new];
        configuration.width = 1920;
        configuration.height = 1080;
        configuration.minimumFrameInterval = CMTimeMake(1, 60);
        configuration.pixelFormat = kCVPixelFormatType_32BGRA;
        configuration.queueDepth = 3;
        configuration.showsCursor = YES;
        configuration.capturesAudio = NO;
        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:nil];
        P21FrameSink *sink = [[P21FrameSink alloc] initWithCounter:frames];
        dispatch_queue_t captureQueue = dispatch_queue_create("openpoly.display.capture", DISPATCH_QUEUE_SERIAL);
        NSError *outputError = nil;
        if (![stream addStreamOutput:sink type:SCStreamOutputTypeScreen
                  sampleHandlerQueue:captureQueue error:&outputError]) {
            fprintf(stderr, "cannot add display capture output: %s\n", outputError.localizedDescription.UTF8String);
            free(frames); return 1;
        }
        dispatch_semaphore_t started = dispatch_semaphore_create(0);
        __block NSError *startError = nil;
        [stream startCaptureWithCompletionHandler:^(NSError *error) {
            startError = error;
            dispatch_semaphore_signal(started);
        }];
        if (dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) || startError) {
            fprintf(stderr, "cannot start display capture: %s\n",
                    startError.localizedDescription.UTF8String ?: "timed out");
            free(frames); return 1;
        }

        printf("virtual-display=%u mode=1920x1080@60 capture=%ds\n", display.displayID, seconds);
        fflush(stdout);
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
        while ([until timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:until];
        }
        dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
        [stream stopCaptureWithCompletionHandler:^(NSError *error) {
            if (error) fprintf(stderr, "display capture stop failed: %s\n", error.localizedDescription.UTF8String);
            dispatch_semaphore_signal(stopped);
        }];
        long stopTimedOut = dispatch_semaphore_wait(
            stopped, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        printf("captured-frames=%u\n", atomic_load_explicit(frames, memory_order_relaxed));
        if (stopTimedOut) {
            fputs("display capture stop timed out\n", stderr);
            // The callback can still reference the counter. Let process exit
            // reclaim it instead of risking a late use-after-free.
            return 1;
        }
        free(frames);
        return 0;
    }
}
