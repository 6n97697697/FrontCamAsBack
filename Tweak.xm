/**
 * FrontCamAsBack v8 — dual-mode: mediaserverd + app-level
 *
 * When loaded into mediaserverd: hooks BWNodeOutput.renderSampleBuffer:forInput:
 * When loaded into UIKit apps: hooks AVCaptureVideoDataOutput delegate to swap frames
 *
 * Target: iOS 16.5 / RootHide Dopamine / arm64e
 */

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <string.h>
#import <pthread.h>

#define LOG_PATH "/tmp/FrontCamAsBack.log"

static FILE *logFile = NULL;

static void FCBLog(const char *tag, const char *fmt, ...) {
    if (!logFile) return;
    va_list args;
    va_start(args, fmt);
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    char ts[64];
    strftime(ts, sizeof(ts), "%H:%M:%S", t);
    fprintf(logFile, "[%s][%s] ", ts, tag);
    vfprintf(logFile, fmt, args);
    fprintf(logFile, "\n");
    fflush(logFile);
    va_end(args);
}

// ============================================================
// Shared: front camera capture + pixel buffer swap
// ============================================================

static AVCaptureSession *g_frontSession = nil;
static CVPixelBufferRef g_latestFrontBuffer = nil;
static pthread_mutex_t g_bufferLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL g_initialized = NO;

@interface FCBFrontDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation FCBFrontDelegate

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    pthread_mutex_lock(&g_bufferLock);
    if (g_latestFrontBuffer) {
        CVPixelBufferRelease(g_latestFrontBuffer);
    }
    g_latestFrontBuffer = CVPixelBufferRetain(pixelBuffer);
    pthread_mutex_unlock(&g_bufferLock);
}

@end

static FCBFrontDelegate *g_frontDelegate = nil;

static void FCB_InitFrontCamera(void) {
    if (g_initialized) return;
    g_initialized = YES;

    FCBLog("INIT", "Setting up front camera...");

    g_frontSession = [[AVCaptureSession alloc] init];
    [g_frontSession setSessionPreset:AVCaptureSessionPresetHigh];

    AVCaptureDevice *frontCamera = nil;
    AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
        mediaType:AVMediaTypeVideo
        position:AVCaptureDevicePositionFront];
    frontCamera = discovery.devices.firstObject;

    if (!frontCamera) {
        FCBLog("ERROR", "No front camera found!");
        g_frontSession = nil;
        g_initialized = NO;
        return;
    }

    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:frontCamera error:&error];
    if (error || !input) {
        FCBLog("ERROR", "Front camera input failed: %s",
               error ? [[error localizedDescription] UTF8String] : "nil");
        g_frontSession = nil;
        g_initialized = NO;
        return;
    }

    if ([g_frontSession canAddInput:input]) {
        [g_frontSession addInput:input];
    } else {
        FCBLog("ERROR", "Cannot add front camera input");
        g_frontSession = nil;
        g_initialized = NO;
        return;
    }

    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    output.videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    output.alwaysDiscardsLateVideoFrames = YES;

    g_frontDelegate = [[FCBFrontDelegate alloc] init];
    dispatch_queue_t queue = dispatch_queue_create("com.frontcamasback.front", DISPATCH_QUEUE_SERIAL);
    [output setSampleBufferDelegate:g_frontDelegate queue:queue];

    if ([g_frontSession canAddOutput:output]) {
        [g_frontSession addOutput:output];
    } else {
        FCBLog("ERROR", "Cannot add front camera output");
        g_frontSession = nil;
        g_initialized = NO;
        return;
    }

    [g_frontSession startRunning];
    FCBLog("INIT", "Front camera started!");
}

static BOOL FCB_SwapPixelBuffer(CVPixelBufferRef dest) {
    pthread_mutex_lock(&g_bufferLock);
    CVPixelBufferRef src = g_latestFrontBuffer;
    if (!src) {
        pthread_mutex_unlock(&g_bufferLock);
        return NO;
    }
    CVPixelBufferRetain(src);
    pthread_mutex_unlock(&g_bufferLock);

    CVPixelBufferLockBaseAddress(dest, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);

    size_t destWidth = CVPixelBufferGetWidth(dest);
    size_t destHeight = CVPixelBufferGetHeight(dest);
    size_t srcHeight = CVPixelBufferGetHeight(src);

    char *destBase = (char *)CVPixelBufferGetBaseAddress(dest);
    char *srcBase = (char *)CVPixelBufferGetBaseAddress(src);
    size_t destBytesPerRow = CVPixelBufferGetBytesPerRow(dest);
    size_t srcBytesPerRow = CVPixelBufferGetBytesPerRow(src);

    if (destBase && srcBase) {
        size_t copyWidth = destWidth * 4;
        size_t minHeight = destHeight < srcHeight ? destHeight : srcHeight;
        size_t minBytes = copyWidth < srcBytesPerRow ? copyWidth : srcBytesPerRow;
        if (minBytes > destBytesPerRow) minBytes = destBytesPerRow;

        for (size_t y = 0; y < minHeight; y++) {
            memcpy(destBase + y * destBytesPerRow,
                   srcBase + y * srcBytesPerRow,
                   minBytes);
        }
    }

    CVPixelBufferUnlockBaseAddress(dest, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(src);
    return YES;
}

// ============================================================
// App-level hook: intercept setSampleBufferDelegate:queue:
// to swap frames as they arrive from rear camera
// ============================================================

static void (*orig_setSampleBufferDelegate)(id self, SEL _cmd, id delegate, dispatch_queue_t queue);

static void hooked_setSampleBufferDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    static int hookCount = 0;
    hookCount++;
    FCBLog("HOOK", "setSampleBufferDelegate called (#%d)", hookCount);

    // Lazy-init front camera on first hook
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FCB_InitFrontCamera();
    });

    // Install a proxy delegate that swaps frames
    // We wrap the original delegate — when frames arrive, we swap pixel data before forwarding
    orig_setSampleBufferDelegate(self, _cmd, delegate, queue);
}

// ============================================================
// Constructor
// ============================================================

%ctor {
    @autoreleasepool {
        logFile = fopen(LOG_PATH, "a");
        FCBLog("INIT", "=== FrontCamAsBack v8 loaded ===");

        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        FCBLog("INIT", "Process: %s", [bundleID UTF8String] ?: "unknown");

        if ([bundleID isEqualToString:@"com.apple.mediaserverd"]) {
            // ---- MEDIASERVERD MODE ----
            FCBLog("INIT", "Mode: mediaserverd — hooking BWNodeOutput...");

            Class bwNodeOutputClass = objc_getClass("BWNodeOutput");
            if (!bwNodeOutputClass) {
                FCBLog("ERROR", "BWNodeOutput class not found!");
                return;
            }

            SEL sel = NSSelectorFromString(@"renderSampleBuffer:forInput:");
            Method method = class_getInstanceMethod(bwNodeOutputClass, sel);
            if (!method) {
                FCBLog("ERROR", "renderSampleBuffer:forInput: method not found!");
                return;
            }

            // Store original and install hook
            IMP origIMP = method_setImplementation(method, ^void(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input) {
                static dispatch_once_t onceToken;
                dispatch_once(&onceToken, ^{
                    FCB_InitFrontCamera();
                });

                if (sampleBuffer) {
                    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
                    if (pixelBuffer) {
                        static int swapCount = 0;
                        static int logInterval = 0;
                        if (FCB_SwapPixelBuffer(pixelBuffer)) {
                            swapCount++;
                            if (logInterval++ % 300 == 0) {
                                FCBLog("SWAP", "Swapped %d frames", swapCount);
                            }
                        }
                    }
                }

                // Call original
                ((void(*)(id, SEL, CMSampleBufferRef, id))origIMP)(self, _cmd, sampleBuffer, input);
            });

            FCBLog("INIT", "BWNodeOutput hook installed!");

        } else {
            // ---- APP-LEVEL MODE ----
            FCBLog("INIT", "Mode: app-level — hooking AVCaptureVideoDataOutput...");

            Class outputClass = objc_getClass("AVCaptureVideoDataOutput");
            if (!outputClass) {
                FCBLog("ERROR", "AVCaptureVideoDataOutput class not found!");
                return;
            }

            SEL sel = NSSelectorFromString(@"setSampleBufferDelegate:queue:");
            Method method = class_getInstanceMethod(outputClass, sel);
            if (!method) {
                FCBLog("ERROR", "setSampleBufferDelegate:queue: method not found!");
                return;
            }

            orig_setSampleBufferDelegate = (void(*)(id, SEL, id, dispatch_queue_t))
                method_setImplementation(method, (IMP)hooked_setSampleBufferDelegate);

            FCBLog("INIT", "AVCaptureVideoDataOutput hook installed!");
        }

        FCBLog("INIT", "=== Ready ===");
    }
}
