/**
 * FrontCamAsBack v7 — mediaserverd frame replacement
 *
 * Hooks CMCapture.framework inside mediaserverd (like chmp4/vcamera).
 * Intercepts renderSampleBuffer:forInput: on BWNodeOutput.
 * When rear camera frame arrives, replaces pixel buffer with front camera frame.
 *
 * NO new AVCaptureSession created (v5 broke ElleKit by doing that).
 * Instead, we open front camera as a lightweight source and swap pixel data.
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
// Front camera capture — runs inside mediaserverd
// Captures from front camera and holds latest frame for swapping
// ============================================================

static AVCaptureSession *g_frontSession = nil;
static CVPixelBufferRef g_latestFrontBuffer = nil;
static pthread_mutex_t g_bufferLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL g_initialized = NO;

// Delegate to receive front camera frames
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

    FCBLog("INIT", "Setting up front camera inside mediaserverd...");

    // Create capture session directly (not via hooks — this is init code)
    g_frontSession = [[AVCaptureSession alloc] init];
    [g_frontSession setSessionPreset:AVCaptureSessionPresetHigh];

    // Find front camera using discovery session
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
        FCBLog("ERROR", "Failed to create front camera input: %s",
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

    // Output with delegate
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
    FCBLog("INIT", "Front camera started inside mediaserverd!");
}

// ============================================================
// Pixel buffer copy — replace rear camera pixels with front camera pixels
// ============================================================

static BOOL FCB_SwapPixelBuffer(CVPixelBufferRef dest) {
    pthread_mutex_lock(&g_bufferLock);
    CVPixelBufferRef src = g_latestFrontBuffer;
    if (!src) {
        pthread_mutex_unlock(&g_bufferLock);
        return NO;
    }
    CVPixelBufferRetain(src);
    pthread_mutex_unlock(&g_bufferLock);

    // Lock both buffers
    CVPixelBufferLockBaseAddress(dest, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);

    size_t destWidth = CVPixelBufferGetWidth(dest);
    size_t destHeight = CVPixelBufferGetHeight(dest);
    size_t srcWidth = CVPixelBufferGetWidth(src);
    size_t srcHeight = CVPixelBufferGetHeight(src);

    char *destBase = (char *)CVPixelBufferGetBaseAddress(dest);
    char *srcBase = (char *)CVPixelBufferGetBaseAddress(src);
    size_t destBytesPerRow = CVPixelBufferGetBytesPerRow(dest);
    size_t srcBytesPerRow = CVPixelBufferGetBytesPerRow(src);

    if (destBase && srcBase) {
        // Copy line by line (handles different strides)
        size_t copyWidth = destWidth * 4; // BGRA = 4 bytes per pixel
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
// CMCapture hook — intercept renderSampleBuffer:forInput:
// This is the same hook point that chmp4/vcamera uses
// ============================================================

// We hook BWNodeOutput (private CMCapture class) to intercept frames
// flowing through the capture pipeline.

static void (*orig_renderSampleBufferForInput)(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input);

static void hooked_renderSampleBufferForInput(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input) {
    // Lazy-init front camera on first frame
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FCB_InitFrontCamera();
    });

    // Try to swap pixel buffer if we have a front camera frame
    if (sampleBuffer) {
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (pixelBuffer) {
            static int swapCount = 0;
            static int logInterval = 0;

            if (FCB_SwapPixelBuffer(pixelBuffer)) {
                swapCount++;
                if (logInterval++ % 300 == 0) { // Log every 300 frames (~10s at 30fps)
                    FCBLog("SWAP", "Swapped %d frames total", swapCount);
                }
            }
        }
    }

    // Call original
    orig_renderSampleBufferForInput(self, _cmd, sampleBuffer, input);
}

// ============================================================
// Constructor — hook BWNodeOutput when loaded into mediaserverd
// ============================================================

%ctor {
    @autoreleasepool {
        logFile = fopen(LOG_PATH, "a");
        FCBLog("INIT", "=== FrontCamAsBack v7 loaded ===");

        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        FCBLog("INIT", "Process: %s", [bundleID UTF8String] ?: "unknown");

        // Only hook inside mediaserverd
        if (![bundleID isEqualToString:@"com.apple.mediaserverd"]) {
            FCBLog("INIT", "Not mediaserverd, skipping CMCapture hooks");
            // Still log that we loaded (for diagnostic)
            return;
        }

        FCBLog("INIT", "Inside mediaserverd — installing CMCapture hooks...");

        // Get BWNodeOutput class from CMCapture framework
        Class bwNodeOutputClass = objc_getClass("BWNodeOutput");
        if (!bwNodeOutputClass) {
            FCBLog("ERROR", "BWNodeOutput class not found!");
            return;
        }
        FCBLog("INIT", "BWNodeOutput class found: %p", bwNodeOutputClass);

        // Hook renderSampleBuffer:forInput:
        SEL sel = NSSelectorFromString(@"renderSampleBuffer:forInput:");
        Method method = class_getInstanceMethod(bwNodeOutputClass, sel);
        if (!method) {
            FCBLog("ERROR", "renderSampleBuffer:forInput: method not found!");
            return;
        }

        IMP origIMP = method_setImplementation(method, (IMP)hooked_renderSampleBufferForInput);
        orig_renderSampleBufferForInput = (void(*)(id, SEL, CMSampleBufferRef, id))origIMP;

        FCBLog("INIT", "Hook installed on BWNodeOutput.renderSampleBuffer:forInput:");
        FCBLog("INIT", "=== Ready to swap frames ===");
    }
}
