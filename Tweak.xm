/**
 * FrontCamAsBack — Jailbreak Tweak (v4 — RootHide compatible)
 *
 * Target: iOS 16.5 / Dopamine / RootHide / arm64e
 * Compatible with vcamera (chmp4) — different hook levels.
 */

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Accelerate/Accelerate.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <pthread.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wobjc-method-access"

#define LOG_PATH "/tmp/FrontCamAsBack.log"
#define PREFS_PATH "/var/mobile/Library/Preferences/com.frontcamasback.plist"

static BOOL tweakEnabled = YES;
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

static void FCBReloadPrefs(void) {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@PREFS_PATH];
    if (p) {
        tweakEnabled = p[@"Enabled"] ? [p[@"Enabled"] boolValue] : YES;
        debugLogging = p[@"Debug"] ? [p[@"Debug"] boolValue] : YES;
    }
}

static void PrefsChanged(CFNotificationCenterRef c, void *o,
                          CFNotificationName n, const void *obj, CFDictionaryRef info) {
    FCBReloadPrefs();
}

// ============================================================================
// MARK: - NV12 Transform Helpers
// ============================================================================

/**
 * Flip NV12 horizontally. Y plane via vImage, UV plane manually
 * (SDK has no interleaved vImage functions).
 */
static void flipNV12(void *ySrc, size_t yBPR,
                     void *uvSrc, size_t uvBPR,
                     void *yDst, size_t yDstBPR,
                     void *uvDst, size_t uvDstBPR,
                     size_t width, size_t height) {
    // Y plane: vImage flip
    vImage_Buffer srcY = { ySrc, height, width, yBPR };
    vImage_Buffer dstY = { yDst, height, width, yDstBPR };
    vImageHorizontalReflect_Planar8(&srcY, &dstY, kvImageNoFlags);

    // UV plane: reverse byte pairs per row
    size_t uvH = height / 2;
    size_t uvW = width / 2;
    for (size_t r = 0; r < uvH; r++) {
        const uint8_t *src = (const uint8_t *)uvSrc + r * uvBPR;
        uint8_t *dst = (uint8_t *)uvDst + r * uvDstBPR;
        for (size_t c = 0; c < uvW; c++) {
            size_t srcOff = c * 2;
            size_t dstOff = (uvW - 1 - c) * 2;
            dst[dstOff]     = src[srcOff];
            dst[dstOff + 1] = src[srcOff + 1];
        }
    }
}

/**
 * Rotate NV12 90/180/270 degrees.
 * Y plane via vImageRotate90_Planar8, UV plane manually.
 */
static void rotateNV12(void *ySrc, size_t yBPR,
                       void *uvSrc, size_t uvBPR,
                       void *yDst, size_t yDstBPR,
                       void *uvDst, size_t uvDstBPR,
                       size_t srcW, size_t srcH,
                       size_t dstW, size_t dstH,
                       int rotation) {
    // Y plane
    vImage_Buffer srcY = { ySrc, srcH, srcW, yBPR };
    vImage_Buffer dstY = { yDst, dstH, dstW, yDstBPR };
    vImageRotate90_Planar8(&srcY, &dstY, (uint8_t)rotation, 0, kvImageNoFlags);

    // UV plane: manual rotation treating 2-byte pairs as units
    size_t uvSrcW = srcW / 2, uvSrcH = srcH / 2;
    size_t uvDstW = dstW / 2, uvDstH = dstH / 2;
    const uint8_t *s = (const uint8_t *)uvSrc;
    uint8_t *d = (uint8_t *)uvDst;

    for (size_t r = 0; r < uvSrcH; r++) {
        for (size_t c = 0; c < uvSrcW; c++) {
            size_t dr, dc;
            switch (rotation) {
                case 1: // 90 CW
                    dr = c;
                    dc = uvSrcH - 1 - r;
                    break;
                case 2: // 180
                    dr = uvSrcH - 1 - r;
                    dc = uvSrcW - 1 - c;
                    break;
                case 3: // 270 CW
                    dr = uvSrcW - 1 - c;
                    dc = r;
                    break;
                default: // 0
                    dr = r; dc = c;
                    break;
            }
            if (dr < uvDstH && dc < uvDstW) {
                size_t srcOff = r * uvBPR + c * 2;
                size_t dstOff = dr * uvDstBPR + dc * 2;
                d[dstOff]     = s[srcOff];
                d[dstOff + 1] = s[srcOff + 1];
            }
        }
    }
}

/**
 * Scale NV12 to target size. Y via vImage, UV manually.
 */
static void scaleNV12(void *ySrc, size_t yBPR,
                       void *uvSrc, size_t uvBPR,
                       void *yDst, size_t yDstBPR,
                       void *uvDst, size_t uvDstBPR,
                       size_t srcW, size_t srcH,
                       size_t dstW, size_t dstH) {
    vImage_Buffer srcY = { ySrc, srcH, srcW, yBPR };
    vImage_Buffer dstY = { yDst, dstH, dstW, yDstBPR };
    vImageScale_Planar8(&srcY, &dstY, NULL, kvImageHighQualityResampling);

    // UV plane: nearest-neighbor scale
    size_t uvSrcW = srcW / 2, uvSrcH = srcH / 2;
    size_t uvDstW = dstW / 2, uvDstH = dstH / 2;
    const uint8_t *s = (const uint8_t *)uvSrc;
    uint8_t *d = (uint8_t *)uvDst;

    for (size_t dr = 0; dr < uvDstH; dr++) {
        size_t sr = (dr * uvSrcH) / uvDstH;
        for (size_t dc = 0; dc < uvDstW; dc++) {
            size_t sc = (dc * uvSrcW) / uvDstW;
            size_t srcOff = sr * uvBPR + sc * 2;
            size_t dstOff = dr * uvDstBPR + dc * 2;
            d[dstOff]     = s[srcOff];
            d[dstOff + 1] = s[srcOff + 1];
        }
    }
}

// ============================================================================
// MARK: - Frame Manager
// ============================================================================

@interface FCBFrameManager : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) AVCaptureSession *frontSession;
@property (nonatomic, strong) dispatch_queue_t captureQueue;
@property (nonatomic, assign) BOOL sessionRunning;
@property (nonatomic, assign) NSInteger frameCount;
@property (nonatomic, assign) NSInteger consecutiveBlack;
@property (nonatomic, assign) CMSampleBufferRef latestBuffer;
@property (nonatomic, assign) pthread_mutex_t lock;
@property (nonatomic, assign) void *tempY;
@property (nonatomic, assign) void *tempUV;
@property (nonatomic, assign) void *flipY;
@property (nonatomic, assign) void *flipUV;
@property (nonatomic, assign) size_t tempBufSize;
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

- (void)allocBuffers:(size_t)size {
    if (_tempBufSize >= size) return;
    [self freeBuffers];
    _tempY = malloc(size);
    _tempUV = malloc(size / 2);
    _flipY = malloc(size);
    _flipUV = malloc(size / 2);
    _tempBufSize = size;
}

- (void)freeBuffers {
    free(_tempY);  _tempY = NULL;
    free(_tempUV); _tempUV = NULL;
    free(_flipY);  _flipY = NULL;
    free(_flipUV); _flipUV = NULL;
    _tempBufSize = 0;
}

- (void)startFrontSession {
    @synchronized(self) {
        if (_sessionRunning) return;

        AVCaptureDevice *dev = nil;
        NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
        for (AVCaptureDevice *d in devices) {
            if (d.position == AVCaptureDevicePositionFront) { dev = d; break; }
        }
        if (!dev) { FCBLog("ERROR", "No front camera"); return; }

        FCBLog("SESSION", "Front: %s", [dev.localizedName UTF8String]);

        NSError *err = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
        if (!input) { FCBLog("ERROR", "Front input: %s", [[err localizedDescription] UTF8String] ?: "unknown"); return; }

        _frontSession = [[AVCaptureSession alloc] init];
        _frontSession.sessionPreset = AVCaptureSessionPreset1920x1080;

        if ([_frontSession canAddInput:input]) [_frontSession addInput:input];
        else { FCBLog("ERROR", "Cannot add input"); return; }

        AVCaptureVideoDataOutput *out = [[AVCaptureVideoDataOutput alloc] init];
        out.videoSettings = @{ (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) };
        out.alwaysDiscardsLateVideoFrames = YES;
        [out setSampleBufferDelegate:self queue:_captureQueue];

        if ([_frontSession canAddOutput:out]) [_frontSession addOutput:out];
        else { FCBLog("ERROR", "Cannot add output"); return; }

        [self allocBuffers:1920 * 1080];
        [_frontSession startRunning];
        _sessionRunning = YES;
        FCBLog("SESSION", "Front session started");
    }
}

- (void)stopFrontSession {
    @synchronized(self) {
        if (!_sessionRunning) return;
        [_frontSession stopRunning];
        _sessionRunning = NO;
        pthread_mutex_lock(&_lock);
        if (_latestBuffer) { CFRelease(_latestBuffer); _latestBuffer = NULL; }
        pthread_mutex_unlock(&_lock);
        [self freeBuffers];
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

- (CMSampleBufferRef)swapFrame:(CMSampleBufferRef)rearBuf
                 withConnection:(AVCaptureConnection *)conn {
    if (!rearBuf) return NULL;

    pthread_mutex_lock(&_lock);
    CMSampleBufferRef frontBuf = _latestBuffer;
    if (frontBuf) CFRetain(frontBuf);
    pthread_mutex_unlock(&_lock);
    if (!frontBuf) return NULL;

    CVImageBufferRef frontImg = CMSampleBufferGetImageBuffer(frontBuf);
    if (!frontImg) { CFRelease(frontBuf); return NULL; }

    // Target size from rear buffer
    size_t targetW = 1920, targetH = 1080;
    CMFormatDescriptionRef rearFmt = CMSampleBufferGetFormatDescription(rearBuf);
    if (rearFmt) {
        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(rearFmt);
        if (d.width > 0 && d.height > 0) { targetW = d.width; targetH = d.height; }
    }

    // Rotation from connection
    int rotDeg = 0;
    if (conn && conn.isVideoOrientationSupported) {
        switch (conn.videoOrientation) {
            case AVCaptureVideoOrientationPortrait:           rotDeg = 0;   break;
            case AVCaptureVideoOrientationPortraitUpsideDown: rotDeg = 180; break;
            case AVCaptureVideoOrientationLandscapeLeft:      rotDeg = 90;  break;
            case AVCaptureVideoOrientationLandscapeRight:     rotDeg = 270; break;
        }
    }

    // vImage rotation constant
    int vImgRot = 0;
    switch (rotDeg) {
        case 90:  vImgRot = 1; break;
        case 180: vImgRot = 2; break;
        case 270: vImgRot = 3; break;
    }

    CVPixelBufferLockBaseAddress(frontImg, kCVPixelBufferLock_ReadOnly);
    size_t srcW = CVPixelBufferGetWidth(frontImg);
    size_t srcH = CVPixelBufferGetHeight(frontImg);
    OSType fmt = CVPixelBufferGetPixelFormatType(frontImg);

    void *srcY  = CVPixelBufferGetBaseAddressOfPlane(frontImg, 0);
    void *srcUV = CVPixelBufferGetBaseAddressOfPlane(frontImg, 1);
    size_t srcYBPR  = CVPixelBufferGetBytesPerRowOfPlane(frontImg, 0);
    size_t srcUVBPR = CVPixelBufferGetBytesPerRowOfPlane(frontImg, 1);

    if (!srcY || !srcUV) {
        CVPixelBufferUnlockBaseAddress(frontImg, kCVPixelBufferLock_ReadOnly);
        CFRelease(frontBuf);
        return NULL;
    }

    size_t interW = srcW, interH = srcH;
    if (rotDeg == 90 || rotDeg == 270) { interW = srcH; interH = srcW; }

    [self allocBuffers:interW * interH];

    if (rotDeg == 0) {
        flipNV12(srcY, srcYBPR, srcUV, srcUVBPR,
                 _tempY, interW, _tempUV, interW, srcW, srcH);
    } else {
        flipNV12(srcY, srcYBPR, srcUV, srcUVBPR,
                 _flipY, srcW, _flipUV, srcW, srcW, srcH);
        rotateNV12(_flipY, srcW, _flipUV, srcW,
                   _tempY, interW, _tempUV, interW,
                   srcW, srcH, interW, interH, vImgRot);
    }

    CVPixelBufferUnlockBaseAddress(frontImg, kCVPixelBufferLock_ReadOnly);

    CVPixelBufferRef outBuf = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, targetW, targetH, fmt, NULL, &outBuf) != kCVReturnSuccess || !outBuf) {
        CFRelease(frontBuf);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(outBuf, 0);
    void *dstY  = CVPixelBufferGetBaseAddressOfPlane(outBuf, 0);
    void *dstUV = CVPixelBufferGetBaseAddressOfPlane(outBuf, 1);
    size_t dstYBPR  = CVPixelBufferGetBytesPerRowOfPlane(outBuf, 0);
    size_t dstUVBPR = CVPixelBufferGetBytesPerRowOfPlane(outBuf, 1);

    if (!dstY || !dstUV) {
        CVPixelBufferUnlockBaseAddress(outBuf, 0);
        CFRelease(outBuf);
        CFRelease(frontBuf);
        return NULL;
    }

    if (interW == targetW && interH == targetH) {
        for (size_t r = 0; r < interH; r++)
            memcpy((uint8_t *)dstY + r * dstYBPR, (const uint8_t *)_tempY + r * interW, MIN(interW, dstYBPR));
        for (size_t r = 0; r < interH / 2; r++)
            memcpy((uint8_t *)dstUV + r * dstUVBPR, (const uint8_t *)_tempUV + r * interW, MIN(interW, dstUVBPR));
    } else {
        scaleNV12(_tempY, interW, _tempUV, interW,
                  dstY, dstYBPR, dstUV, dstUVBPR,
                  interW, interH, targetW, targetH);
    }

    CVPixelBufferUnlockBaseAddress(outBuf, 0);

    CMFormatDescriptionRef outFmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, outBuf, &outFmt) != noErr) {
        CFRelease(outBuf);
        CFRelease(frontBuf);
        return NULL;
    }

    CMSampleTimingInfo timing;
    timing.duration = CMSampleBufferGetDuration(rearBuf);
    timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(rearBuf);
    timing.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef result = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, outBuf, outFmt, &timing, &result);

    CFRelease(outFmt);
    CFRelease(outBuf);
    CFRelease(frontBuf);

    if (result) {
        _frameCount++;
        if (_frameCount % 100 == 0)
            FCBLog("FRAME", "Swapped %ld | %zux%zu->%zux%zu rot=%d", (long)_frameCount, srcW, srcH, targetW, targetH, rotDeg);
    }
    return result;
}

@end

// ============================================================================
// MARK: - Proxy Delegate
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
            CMSampleBufferRef swapped = [[FCBFrameManager shared] swapFrame:sampleBuffer withConnection:connection];
            if (swapped) {
                [delegate captureOutput:output didOutputSampleBuffer:swapped fromConnection:connection];
                CFRelease(swapped);
            } else {
                [delegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
            }
        } else {
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

%hook AVCaptureDeviceDiscoverySession

+ (instancetype)discoverySessionWithDeviceTypes:(NSArray *)types
                                      mediaType:(NSString *)media
                                        position:(AVCaptureDevicePosition)pos {
    if (pos == AVCaptureDevicePositionBack)
        FCBLog("DISCOVERY", "Rear query: %s", [media UTF8String]);
    return %orig;
}

%end

%hook AVCaptureDeviceInput

+ (instancetype)deviceInputWithDevice:(AVCaptureDevice *)device error:(NSError **)error {
    if (device.position == AVCaptureDevicePositionBack)
        FCBLog("INPUT", "Rear device: %s", [device.localizedName UTF8String]);
    return %orig;
}

%end

%hook AVCaptureSession

- (void)addInput:(AVCaptureInput *)input {
    %orig;
    if ([input isKindOfClass:%c(AVCaptureDeviceInput)]) {
        AVCaptureDeviceInput *di = (AVCaptureDeviceInput *)input;
        if (di.device.position == AVCaptureDevicePositionBack) {
            pthread_mutex_lock(&g_stateLock);
            [g_sessionsWithRear addObject:@((uintptr_t)self)];
            pthread_mutex_unlock(&g_stateLock);
            FCBLog("SESSION", "Rear input -> session %p", self);
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
        FCBLog("SESSION", "Session %p rear starting", self);
        [[FCBFrameManager shared] startFrontSession];

        pthread_mutex_lock(&g_stateLock);
        NSDictionary *copy = [g_pendingDelegates copy];
        [g_pendingDelegates removeAllObjects];
        pthread_mutex_unlock(&g_stateLock);

        for (NSNumber *outputKey in copy) {
            id delegate = copy[outputKey][@"delegate"];
            dispatch_queue_t queue = copy[outputKey][@"queue"];
            AVCaptureVideoDataOutput *output = copy[outputKey][@"output"];
            if (delegate && queue && output) {
                FCBLog("DELEGATE", "Connect pending for %p", (void *)[outputKey unsignedIntegerValue]);
                FCBProxyDelegate *proxy = [[FCBProxyDelegate alloc] init];
                proxy.originalDelegate = delegate;
                [output setSampleBufferDelegate:proxy queue:queue];
            }
        }
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

    if ([FCBFrameManager shared].sessionRunning) {
        FCBLog("DELEGATE", "Intercept output %p", self);
        FCBProxyDelegate *proxy = [[FCBProxyDelegate alloc] init];
        proxy.originalDelegate = delegate;
        %orig(proxy, queue);
        return;
    }

    FCBLog("DELEGATE", "Pending output %p", self);
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
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundleID isEqualToString:@"com.apple.mediaserverd"]) return;

        logFile = fopen(LOG_PATH, "a");
        FCBReloadPrefs();
        ensureState();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, PrefsChanged,
            CFSTR("com.frontcamasback/preferencesChanged"),
            NULL, CFNotificationSuspensionBehaviorCoalesce);

        FCBLog("INIT", "=== FrontCamAsBack v4 loaded ===");
        FCBLog("INIT", "Bundle: %s", [bundleID UTF8String] ?: "?");
    }
}

#pragma clang diagnostic pop
