/**
 * FrontCamAsBack — mediaserverd level (v5)
 *
 * Hooks mediaserverd to replace broken rear camera with front camera.
 * Works for ALL apps automatically — no per-app injection needed.
 *
 * Target: iOS 16.5 / Dopamine / rootless / arm64e
 */

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <pthread.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wobjc-method-access"

#define LOG_PATH "/tmp/FrontCamAsBack.log"

static BOOL debugLogging = YES;
static FILE *logFile = NULL;

static void FCBLog(const char *tag, const char *fmt, ...) {
    if (!debugLogging && strcmp(tag, "DEBUG") == 0) return;
    va_list args;
    va_start(args, fmt);
    if (logFile) {
        time_t now = time(NULL);
        struct tm *t = localtime(&now);
        char ts[64];
        strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", t);
        fprintf(logFile, "[%s] [%s] ", ts, tag);
        vfprintf(logFile, fmt, args);
        fprintf(logFile, "\n");
        fflush(logFile);
    }
    va_end(args);
}

// ============================================================================
// MARK: - Front Camera Session (runs inside mediaserverd)
// ============================================================================

@interface FCBFrameManager : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) AVCaptureSession *frontSession;
@property (nonatomic, strong) dispatch_queue_t captureQueue;
@property (nonatomic, assign) BOOL sessionRunning;
@property (nonatomic, assign) CMSampleBufferRef latestBuffer;
@property (nonatomic, assign) pthread_mutex_t lock;
@end

@implementation FCBFrameManager

+ (instancetype)shared {
    static FCBFrameManager *m = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ m = [[FCBFrameManager alloc] init]; });
    return m;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _captureQueue = dispatch_queue_create("com.frontcamasback.cap", DISPATCH_QUEUE_SERIAL);
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&_lock, &attr);
        pthread_mutexattr_destroy(&attr);
    }
    return self;
}

- (void)startFrontSession {
    @synchronized(self) {
        if (_sessionRunning) return;

        // Find front camera
        AVCaptureDevice *dev = nil;
        NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
        for (AVCaptureDevice *d in devices) {
            if (d.position == AVCaptureDevicePositionFront) { dev = d; break; }
        }
        if (!dev) { FCBLog("ERROR", "No front camera available"); return; }

        FCBLog("SESSION", "Starting front camera: %s", [dev.localizedName UTF8String]);

        NSError *err = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
        if (!input) {
            FCBLog("ERROR", "Front camera input failed: %s", [[err localizedDescription] UTF8String] ?: "unknown");
            return;
        }

        _frontSession = [[AVCaptureSession alloc] init];
        _frontSession.sessionPreset = AVCaptureSessionPreset1920x1080;

        if ([_frontSession canAddInput:input]) {
            [_frontSession addInput:input];
        } else {
            FCBLog("ERROR", "Cannot add front camera input");
            return;
        }

        AVCaptureVideoDataOutput *out = [[AVCaptureVideoDataOutput alloc] init];
        out.videoSettings = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        };
        out.alwaysDiscardsLateVideoFrames = YES;
        [out setSampleBufferDelegate:self queue:_captureQueue];

        if ([_frontSession canAddOutput:out]) {
            [_frontSession addOutput:out];
        } else {
            FCBLog("ERROR", "Cannot add front camera output");
            return;
        }

        [_frontSession startRunning];
        _sessionRunning = YES;
        FCBLog("SESSION", "Front camera session started successfully");
    }
}

- (void)captureOutput:(AVCaptureVideoDataOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    pthread_mutex_lock(&_lock);
    if (_latestBuffer) CFRelease(_latestBuffer);
    _latestBuffer = sampleBuffer;
    CFRetain(_latestBuffer);
    pthread_mutex_unlock(&_lock);
}

- (CMSampleBufferRef)latestBufferCopy {
    pthread_mutex_lock(&_lock);
    CMSampleBufferRef buf = _latestBuffer;
    if (buf) CFRetain(buf);
    pthread_mutex_unlock(&_lock);
    return buf;
}

@end

// ============================================================================
// MARK: - Proxy Delegate — intercepts rear camera frames
// ============================================================================

@interface FCBProxyDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> originalDelegate;
@property (nonatomic, assign) NSInteger consecutiveBlack;
@end

@implementation FCBProxyDelegate

- (void)captureOutput:(AVCaptureVideoDataOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = _originalDelegate;
    if (!delegate) return;

    // Check if frame is black (broken rear camera)
    CVImageBufferRef imgBuf = CMSampleBufferGetImageBuffer(sampleBuffer);
    BOOL isBlack = NO;

    if (imgBuf) {
        CVPixelBufferLockBaseAddress(imgBuf, kCVPixelBufferLock_ReadOnly);
        void *yPlane = CVPixelBufferGetBaseAddressOfPlane(imgBuf, 0);
        size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(imgBuf, 0);
        size_t height = CVPixelBufferGetHeightOfPlane(imgBuf, 0);

        if (yPlane && bpr > 0 && height > 0) {
            uint8_t *pix = (uint8_t *)yPlane;
            isBlack = YES;
            // Sample 10 rows across the frame
            size_t step = height / 10;
            if (step < 1) step = 1;
            for (size_t r = 0; r < 10 && isBlack; r++) {
                size_t row = r * step;
                if (row >= height) break;
                for (size_t i = 0; i < MIN(200, bpr); i++) {
                    if (pix[row * bpr + i] > 10) { isBlack = NO; break; }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(imgBuf, kCVPixelBufferLock_ReadOnly);
    }

    if (isBlack) {
        _consecutiveBlack++;
        if (_consecutiveBlack >= 3) {
            // Rear camera is broken — swap with front camera
            CMSampleBufferRef frontBuf = [[FCBFrameManager shared] latestBufferCopy];
            if (frontBuf) {
                // Try to create a new sample buffer from front camera
                CVImageBufferRef frontImg = CMSampleBufferGetImageBuffer(frontBuf);
                if (frontImg) {
                    // Get target dimensions from rear buffer
                    size_t targetW = 1920, targetH = 1080;
                    CMFormatDescriptionRef rearFmt = CMSampleBufferGetFormatDescription(sampleBuffer);
                    if (rearFmt) {
                        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(rearFmt);
                        if (d.width > 0 && d.height > 0) { targetW = d.width; targetH = d.height; }
                    }

                    // Create output buffer
                    OSType fmt = CVPixelBufferGetPixelFormatType(frontImg);
                    CVPixelBufferRef outBuf = NULL;
                    if (CVPixelBufferCreate(kCFAllocatorDefault, targetW, targetH, fmt, NULL, &outBuf) == kCVReturnSuccess && outBuf) {
                        // Copy front camera pixels to output (simple copy, no transform for now)
                        CVPixelBufferLockBaseAddress(frontImg, kCVPixelBufferLock_ReadOnly);
                        CVPixelBufferLockBaseAddress(outBuf, 0);

                        void *srcY = CVPixelBufferGetBaseAddressOfPlane(frontImg, 0);
                        void *srcUV = CVPixelBufferGetBaseAddressOfPlane(frontImg, 1);
                        size_t srcYBPR = CVPixelBufferGetBytesPerRowOfPlane(frontImg, 0);
                        size_t srcUVBPR = CVPixelBufferGetBytesPerRowOfPlane(frontImg, 1);
                        size_t srcW = CVPixelBufferGetWidth(frontImg);
                        size_t srcH = CVPixelBufferGetHeight(frontImg);

                        void *dstY = CVPixelBufferGetBaseAddressOfPlane(outBuf, 0);
                        void *dstUV = CVPixelBufferGetBaseAddressOfPlane(outBuf, 1);
                        size_t dstYBPR = CVPixelBufferGetBytesPerRowOfPlane(outBuf, 0);
                        size_t dstUVBPR = CVPixelBufferGetBytesPerRowOfPlane(outBuf, 1);

                        if (srcY && srcUV && dstY && dstUV) {
                            size_t copyW = MIN(srcW, targetW);
                            size_t copyH = MIN(srcH, targetH);
                            for (size_t r = 0; r < copyH; r++) {
                                memcpy((uint8_t *)dstY + r * dstYBPR, (const uint8_t *)srcY + r * srcYBPR, copyW);
                            }
                            for (size_t r = 0; r < copyH / 2; r++) {
                                memcpy((uint8_t *)dstUV + r * dstUVBPR, (const uint8_t *)srcUV + r * srcUVBPR, copyW);
                            }
                        }

                        CVPixelBufferUnlockBaseAddress(outBuf, 0);
                        CVPixelBufferUnlockBaseAddress(frontImg, kCVPixelBufferLock_ReadOnly);

                        // Create new sample buffer
                        CMFormatDescriptionRef outFmt = NULL;
                        if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, outBuf, &outFmt) == noErr) {
                            CMSampleTimingInfo timing;
                            timing.duration = CMSampleBufferGetDuration(sampleBuffer);
                            timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
                            timing.decodeTimeStamp = kCMTimeInvalid;

                            CMSampleBufferRef result = NULL;
                            if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, outBuf, outFmt, &timing, &result) == noErr && result) {
                                CFRelease(outFmt);
                                CFRelease(outBuf);
                                CFRelease(frontBuf);
                                [delegate captureOutput:output didOutputSampleBuffer:result fromConnection:connection];
                                CFRelease(result);
                                return;
                            }
                            CFRelease(outFmt);
                        }
                        CFRelease(outBuf);
                    }
                }
                CFRelease(frontBuf);
            }
            // Fallback: pass original (black) frame
            [delegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        } else {
            // First 2 black frames — pass through (avoid glitch at start)
            [delegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        }
    } else {
        _consecutiveBlack = 0;
        [delegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

@end

// ============================================================================
// MARK: - Tracking State
// ============================================================================

static NSMutableSet *g_sessionsWithRear = nil;
static NSMutableDictionary *g_pendingDelegates = nil;
static pthread_mutex_t g_stateLock = PTHREAD_MUTEX_INITIALIZER;

static void ensureState(void) {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        g_sessionsWithRear = [[NSMutableSet alloc] init];
        g_pendingDelegates = [[NSMutableDictionary alloc] init];
    });
}

// ============================================================================
// MARK: - Logos Hooks
// ============================================================================

%hook AVCaptureSession

- (void)addInput:(AVCaptureInput *)input {
    %orig;
    if ([input isKindOfClass:%c(AVCaptureDeviceInput)]) {
        AVCaptureDeviceInput *di = (AVCaptureDeviceInput *)input;
        if (di.device.position == AVCaptureDevicePositionBack) {
            pthread_mutex_lock(&g_stateLock);
            [g_sessionsWithRear addObject:@((uintptr_t)self)];
            pthread_mutex_unlock(&g_stateLock);
            FCBLog("SESSION", "Rear input added to session %p", self);

            // Start front camera if not running
            [[FCBFrameManager shared] startFrontSession];
        }
    }
}

- (void)startRunning {
    NSNumber *key = @((uintptr_t)self);
    BOOL hasRear = NO;
    pthread_mutex_lock(&g_stateLock);
    hasRear = [g_sessionsWithRear containsObject:key];
    pthread_mutex_unlock(&g_stateLock);

    if (hasRear) {
        FCBLog("SESSION", "Session %p starting with rear camera", self);

        // Process pending delegates
        pthread_mutex_lock(&g_stateLock);
        NSDictionary *copy = [g_pendingDelegates copy];
        [g_pendingDelegates removeAllObjects];
        pthread_mutex_unlock(&g_stateLock);

        for (NSNumber *outputKey in copy) {
            id delegate = copy[outputKey][@"delegate"];
            dispatch_queue_t queue = copy[outputKey][@"queue"];
            AVCaptureVideoDataOutput *output = copy[outputKey][@"output"];
            if (delegate && queue && output) {
                FCBLog("DELEGATE", "Installing proxy for pending output %p", (void *)[outputKey unsignedIntegerValue]);
                FCBProxyDelegate *proxy = [[FCBProxyDelegate alloc] init];
                proxy.originalDelegate = delegate;
                [output setSampleBufferDelegate:proxy queue:queue];
            }
        }
    }
    %orig;
}

- (void)stopRunning {
    NSNumber *key = @((uintptr_t)self);
    BOOL hasRear = NO;
    pthread_mutex_lock(&g_stateLock);
    hasRear = [g_sessionsWithRear containsObject:key];
    pthread_mutex_unlock(&g_stateLock);

    if (hasRear) {
        FCBLog("SESSION", "Session %p stopping", self);
    }
    %orig;
}

%end

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (!delegate || [delegate isKindOfClass:%c(FCBProxyDelegate)]) {
        %orig;
        return;
    }

    // Check if this output belongs to a session with rear camera
    BOOL hasRear = NO;
    pthread_mutex_lock(&g_stateLock);
    // Check all tracked sessions — if any has rear, this output might be for rear camera
    hasRear = [g_sessionsWithRear count] > 0;
    pthread_mutex_unlock(&g_stateLock);

    if (hasRear && [FCBFrameManager shared].sessionRunning) {
        FCBLog("DELEGATE", "Intercepting delegate on output %p", self);
        FCBProxyDelegate *proxy = [[FCBProxyDelegate alloc] init];
        proxy.originalDelegate = delegate;
        %orig(proxy, queue);
        return;
    }

    // Not a rear camera session — store as pending in case session starts later
    FCBLog("DELEGATE", "Pending output %p (waiting for session start)", self);
    NSNumber *key = @((uintptr_t)self);
    pthread_mutex_lock(&g_stateLock);
    g_pendingDelegates[key] = @{ @"delegate": delegate, @"queue": queue, @"output": self };
    pthread_mutex_unlock(&g_stateLock);

    %orig;
}

%end

// ============================================================================
// MARK: - Constructor
// ============================================================================

%ctor {
    @autoreleasepool {
        logFile = fopen(LOG_PATH, "a");
        ensureState();

        FCBLog("INIT", "=== FrontCamAsBack v5 loaded (mediaserverd) ===");
        FCBLog("INIT", "Process: %s", [[[NSProcessInfo processInfo] processName] UTF8String] ?: "?");

        // Start front camera immediately
        [[FCBFrameManager shared] startFrontSession];
    }
}

#pragma clang diagnostic pop
