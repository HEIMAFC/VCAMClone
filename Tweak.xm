#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import <notify.h>
#import <substrate.h>
#import <math.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <sys/types.h>
#import <errno.h>
#import <fcntl.h>
#import <unistd.h>

static NSString *const kVCAMConfigPath     = @"/var/tmp/vcam_stream.conf";
static NSString *const kVCAMProcessLogPath = @"/var/tmp/vcam_proc.log";
static NSString *const kVCAMMediaLogPath   = @"/var/tmp/vcam_media.log";
static const char *kVCAMConfigNotify       = "com.vcam.stream.config";
static const char *kVCAMMediaNotify        = "com.vcam.media.stream.recv";

static CVImageBufferRef (*gOrigCMSampleBufferGetImageBuffer)(CMSampleBufferRef sampleBuffer) = NULL;
static CFTimeInterval  gVCAMLastManagerSyncAt  = 0;
static uint64_t        gVCAMHookProbeCount     = 0;

// ─── TCP helpers ──────────────────────────────────────────────────────────────
static BOOL VCAMReadExact(int fd, void *buffer, size_t length) {
    uint8_t *ptr = (uint8_t *)buffer;
    size_t done = 0;
    while (done < length) {
        ssize_t r = recv(fd, ptr + done, length - done, 0);
        if (r <= 0) return NO;
        done += (size_t)r;
    }
    return YES;
}

static int VCAMConnectWithTimeout(const char *host, int port, int timeoutSec) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len    = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port   = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        close(fd); errno = EINVAL; return -1;
    }

    int r = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (r != 0 && errno != EINPROGRESS) {
        int e = errno; close(fd); errno = e; return -1;
    }

    if (r != 0) {
        fd_set wfds; FD_ZERO(&wfds); FD_SET(fd, &wfds);
        struct timeval tv = { timeoutSec > 0 ? timeoutSec : 2, 0 };
        int sel = select(fd + 1, NULL, &wfds, NULL, &tv);
        if (sel <= 0) {
            int e = (sel == 0) ? ETIMEDOUT : errno; close(fd); errno = e; return -1;
        }
        int soError = 0; socklen_t soLen = sizeof(soError);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen) != 0 || soError != 0) {
            int e = soError ? soError : errno; close(fd); errno = e; return -1;
        }
    }

    if (flags >= 0) fcntl(fd, F_SETFL, flags);
    return fd;
}

// ─── JPEG → CVPixelBufferRef (32BGRA) — 纯 ImageIO，不依赖 UIKit ─────────────
static CVPixelBufferRef VCAMCreatePixelBufferFromJPEGData(NSData *jpegData) {
    if (!jpegData.length) return NULL;

    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)jpegData);
    if (!provider) return NULL;

    CGImageRef cgImage = CGImageCreateWithJPEGDataProvider(provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!cgImage) return NULL;

    size_t w = CGImageGetWidth(cgImage);
    size_t h = CGImageGetHeight(cgImage);
    if (w == 0 || h == 0) { CGImageRelease(cgImage); return NULL; }

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey:              @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey:          @{},
        (id)kCVPixelBufferCGImageCompatibilityKey:         @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };

    CVPixelBufferRef buf = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &buf) != kCVReturnSuccess || !buf) {
        CGImageRelease(cgImage); return NULL;
    }

    CVPixelBufferLockBaseAddress(buf, 0);
    CGColorSpaceRef cs  = CGColorSpaceCreateDeviceRGB();
    CGContextRef    ctx = CGBitmapContextCreate(
        CVPixelBufferGetBaseAddress(buf), w, h, 8,
        CVPixelBufferGetBytesPerRow(buf), cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cgImage);
        CGContextRelease(ctx);
    }
    CVPixelBufferUnlockBaseAddress(buf, 0);
    CGImageRelease(cgImage);
    return buf;
}

// ─── CMSampleBuffer attachment helper ────────────────────────────────────────
static void VCAMSetSampleAttachments(CMSampleBufferRef sample) {
    if (!sample) return;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
    if (!attachments || CFArrayGetCount(attachments) <= 0) return;
    CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    if (!dict) return;
    CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    CFDictionaryRemoveValue(dict, kCMSampleAttachmentKey_NotSync);
}

@class VCAMService;

// ─── Logging ──────────────────────────────────────────────────────────────────
static void VCAMAppendLog(NSString *path, NSString *line) {
    if (!line.length) return;
    NSString *entry = [NSString stringWithFormat:@"%.3f %@\n", CFAbsoluteTimeGetCurrent(), line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) { [entry writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    @try { [fh seekToEndOfFile]; [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]]; }
    @catch (__unused NSException *e) {}
    @try { [fh closeFile]; } @catch (__unused NSException *e) {}
}
static void VCAMAppendProcessLog(NSString *line) { VCAMAppendLog(kVCAMProcessLogPath, line); }
static void VCAMAppendMediaLog(NSString *line)   { VCAMAppendLog(kVCAMMediaLogPath,   line); }

// ─── Forward declarations ─────────────────────────────────────────────────────
@interface VCAMStreamReceiver : NSObject
- (void)startWithHost:(NSString *)host port:(int)port;
- (void)stop;
- (CMSampleBufferRef)copyLatestSampleBuffer;
- (CVImageBufferRef)copyLatestImageBuffer;
- (CGImageRef)copyLatestCGImage; // +1 ref，调用方负责 CGImageRelease
@end

@interface VCAMService : NSObject
+ (instancetype)shared;
- (void)startObserver;
- (void)applyConfig;
- (void)syncAndCheckStatus;
- (void)ensureReceiverStartedIfNeeded;
- (CMSampleBufferRef)copyLatestSampleBuffer;
- (CVImageBufferRef)copyLatestImageBuffer;
- (CGImageRef)copyLatestCGImage;
@end

@interface VCAMManager : NSObject
+ (void)syncAndCheckStatus;
+ (CMSampleBufferRef)copyLatestSampleBuffer;
+ (CVImageBufferRef)copyLatestImageBuffer;
+ (CGImageRef)copyLatestCGImage;
@end

// ─── Shared CIContext ─────────────────────────────────────────────────────────
static CIContext *VCAMSharedCIContext(void) {
    static CIContext *sCtx = nil;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{
        sCtx = [CIContext contextWithOptions:nil];
        VCAMAppendMediaLog(sCtx ? @"CIContext ok" : @"CIContext failed");
    });
    return sCtx;
}

// ─── 原地覆写：把假画面像素直接写入真实 buffer 的内存 ─────────────────────────
//
//  比例策略：Aspect-Fill 居中裁切
//    - 按目标宽高等比放大，使假画面能覆盖整个目标区域
//    - 超出部分从中心裁去，避免拉伸和黑边
//
//  路径 A (BGRA)   → CGBitmapContext 直接覆写，零格式转换
//  路径 B (NV12…) → CIContext render:toCVPixelBuffer:bounds: 精确裁切渲染
//                   渲染后 lock/unlock 强制 IOSurface 同步，防止录制时 buffer 被提前复用
// ─────────────────────────────────────────────────────────────────────────────
static BOOL VCAMReplacePixelsInPlace(CGImageRef fakeImage, CVPixelBufferRef realBuf) {
    if (!fakeImage || !realBuf) return NO;

    size_t srcW   = CGImageGetWidth(fakeImage);
    size_t srcH   = CGImageGetHeight(fakeImage);
    size_t dstW   = CVPixelBufferGetWidth(realBuf);
    size_t dstH   = CVPixelBufferGetHeight(realBuf);
    OSType dstFmt = CVPixelBufferGetPixelFormatType(realBuf);

    if (!srcW || !srcH || !dstW || !dstH) return NO;

    // Aspect-Fill：等比放大到刚好能覆盖目标尺寸
    CGFloat fillScale = MAX((CGFloat)dstW / (CGFloat)srcW,
                            (CGFloat)dstH / (CGFloat)srcH);
    CGFloat scaledW   = srcW * fillScale;
    CGFloat scaledH   = srcH * fillScale;

    static uint64_t sReplaceCount = 0;
    sReplaceCount++;
    if (sReplaceCount <= 5 || (sReplaceCount % 300) == 0)
        VCAMAppendMediaLog([NSString stringWithFormat:
            @"replace#=%llu src=%zux%zu dst=%zux%zu fmt=%u scale=%.2f",
            (unsigned long long)sReplaceCount, srcW, srcH, dstW, dstH,
            (unsigned)dstFmt, fillScale]);

    if (dstFmt == kCVPixelFormatType_32BGRA || dstFmt == kCVPixelFormatType_32ARGB) {
        // ── 路径 A：CGBitmapContext 直接覆写 BGRA 内存 ────────────────────────
        // drawRect 居中偏移，让放大后的图片中心对齐目标中心
        CGRect drawRect = CGRectMake(
            -(scaledW - (CGFloat)dstW) * 0.5,
            -(scaledH - (CGFloat)dstH) * 0.5,
            scaledW, scaledH);

        CVPixelBufferLockBaseAddress(realBuf, 0);
        CGColorSpaceRef cs  = CGColorSpaceCreateDeviceRGB();
        CGContextRef    ctx = CGBitmapContextCreate(
            CVPixelBufferGetBaseAddress(realBuf), dstW, dstH, 8,
            CVPixelBufferGetBytesPerRow(realBuf), cs,
            kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipLast);
        CGColorSpaceRelease(cs);
        if (ctx) {
            CGContextClipToRect(ctx, CGRectMake(0, 0, (CGFloat)dstW, (CGFloat)dstH));
            CGContextDrawImage(ctx, drawRect, fakeImage);
            CGContextRelease(ctx);
        }
        CVPixelBufferUnlockBaseAddress(realBuf, 0);
        if (sReplaceCount <= 5) VCAMAppendMediaLog(@"replace A (BGRA) ok");
        return YES;
    }

    // ── 路径 B：CIContext 渲染到 NV12/YpCbCr 等格式 ──────────────────────────
    @autoreleasepool {
        CIImage *ci = [CIImage imageWithCGImage:fakeImage];
        if (!ci) { if (sReplaceCount <= 5) VCAMAppendMediaLog(@"CIImage nil"); return NO; }

        CIContext *ctx = VCAMSharedCIContext();
        if (!ctx) { if (sReplaceCount <= 5) VCAMAppendMediaLog(@"CIContext nil"); return NO; }

        // 先等比放大
        CIImage *scaled = [ci imageByApplyingTransform:
            CGAffineTransformMakeScale(fillScale, fillScale)];

        // bounds：在已放大的 CIImage 坐标系里居中取 dstW×dstH 的区域
        // render:toCVPixelBuffer:bounds: 会把该区域自动填满整个 pixel buffer
        CGRect cropRect = CGRectMake(
            (scaledW - (CGFloat)dstW) * 0.5,
            (scaledH - (CGFloat)dstH) * 0.5,
            (CGFloat)dstW, (CGFloat)dstH);

        [ctx render:scaled toCVPixelBuffer:realBuf bounds:cropRect colorSpace:nil];

        // IOSurface 同步：强制等待 GPU 写完，防止视频录制 buffer 提前被回收导致卡帧
        CVPixelBufferLockBaseAddress(realBuf, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(realBuf, kCVPixelBufferLock_ReadOnly);

        if (sReplaceCount <= 5) VCAMAppendMediaLog(@"replace B (CIContext) ok");
        return YES;
    }
}

// ─── The actual hook function ─────────────────────────────────────────────────
static CVImageBufferRef VCAMHookedCMSampleBufferGetImageBuffer(CMSampleBufferRef sampleBuffer) {
    if (!gOrigCMSampleBufferGetImageBuffer) return NULL;
    [VCAMManager syncAndCheckStatus];

    CVImageBufferRef originalImage = gOrigCMSampleBufferGetImageBuffer(sampleBuffer);
    gVCAMHookProbeCount++;

    // 前 5 次 + 每 300 次打一行日志，确认 hook 正在触发
    if (gVCAMHookProbeCount <= 5 || (gVCAMHookProbeCount % 300) == 0)
        VCAMAppendMediaLog([NSString stringWithFormat:
            @"hook probe=%llu origImg=%s",
            (unsigned long long)gVCAMHookProbeCount,
            originalImage ? "yes" : "null"]);

    if (originalImage) {
        CGImageRef fakeImage = [VCAMManager copyLatestCGImage]; // +1
        if (fakeImage) {
            VCAMReplacePixelsInPlace(fakeImage, (CVPixelBufferRef)originalImage);
            CGImageRelease(fakeImage);
        }
    }

    // 始终返回原始 buffer（像素已被原地覆写，所有 Attachment/IOSurface 完整保留）
    return originalImage;
}

// ─── VCAMStreamReceiver (MJPEG) ───────────────────────────────────────────────
@interface VCAMStreamReceiver ()
- (void)connectLoop:(NSNumber *)generationObj;
- (void)resetStreamStateLocked;
- (void)storeImageBuffer:(CVImageBufferRef)imageBuffer;
@end

@implementation VCAMStreamReceiver {
    NSString      *_host;
    int            _port;
    BOOL           _running;
    int            _socketFD;
    NSThread      *_loopThread;
    NSInteger      _generation;

    CMSampleBufferRef  _latestSample;
    CVImageBufferRef   _latestImageBuffer;
    CGImageRef         _latestCGImage;    // 额外保留 CGImage 供原地覆写路径使用
    uint64_t           _frameCount;
    int                _connectFailCount;
}

- (instancetype)init {
    self = [super init];
    if (self) _socketFD = -1;
    return self;
}

- (void)dealloc {
    [self stop];
    @synchronized (self) { [self resetStreamStateLocked]; }
}

- (void)closeSocketLocked {
    if (_socketFD >= 0) {
        shutdown(_socketFD, SHUT_RDWR);
        close(_socketFD);
        _socketFD = -1;
    }
}

- (void)resetStreamStateLocked {
    if (_latestSample)      { CFRelease(_latestSample);      _latestSample      = NULL; }
    if (_latestImageBuffer) { CFRelease(_latestImageBuffer); _latestImageBuffer = NULL; }
    if (_latestCGImage)     { CGImageRelease(_latestCGImage); _latestCGImage    = NULL; }
}

- (void)startWithHost:(NSString *)host port:(int)port {
    if (!host.length || port <= 0 || port > 65535) {
        VCAMAppendMediaLog([NSString stringWithFormat:@"startWithHost ignored host=%@ port=%d", host ?: @"(nil)", port]);
        return;
    }
    @synchronized (self) {
        if (_running && [_host isEqualToString:host] && _port == port) return;
        [self closeSocketLocked];
        _running = NO;
        _generation++;
        _host    = [host copy];
        _port    = port;
        _running = YES;
        _connectFailCount = 0;
        [self resetStreamStateLocked];

        NSInteger gen = _generation;
        _loopThread = [[NSThread alloc] initWithTarget:self selector:@selector(connectLoop:) object:@(gen)];
        _loopThread.name = @"VCAMClone.ConnectLoop";
        [_loopThread start];
    }
    VCAMAppendMediaLog([NSString stringWithFormat:@"receiver start host=%@ port=%d", host, port]);
}

- (void)stop {
    @synchronized (self) {
        _running = NO;
        _generation++;
        [self closeSocketLocked];
        [self resetStreamStateLocked];
    }
    VCAMAppendMediaLog(@"receiver stop");
}

- (void)connectLoop:(NSNumber *)generationObj {
    NSInteger generation = generationObj.integerValue;
    @autoreleasepool {
        while (YES) {
            @autoreleasepool {
                NSString *host = nil; int port = 0;
                @synchronized (self) {
                    if (!_running || generation != _generation) break;
                    host = _host; port = _port;
                }

                int fd = VCAMConnectWithTimeout(host.UTF8String, port, 2);
                if (fd < 0) {
                    _connectFailCount++;
                    if (_connectFailCount <= 5 || (_connectFailCount % 15) == 0)
                        VCAMAppendMediaLog([NSString stringWithFormat:
                            @"connect failed host=%@ port=%d errno=%d", host ?: @"(nil)", port, errno]);
                    [NSThread sleepForTimeInterval:2.0];
                    continue;
                }

                _connectFailCount = 0;
                VCAMAppendMediaLog([NSString stringWithFormat:@"connected host=%@ port=%d", host, port]);

                @synchronized (self) {
                    if (!_running || generation != _generation) { close(fd); break; }
                    _socketFD = fd;
                }

                // ── Read loop: [4-byte BE length][JPEG payload] ──
                BOOL shouldContinue = YES;
                while (shouldContinue) {
                    @autoreleasepool {
                        @synchronized (self) {
                            if (!_running || generation != _generation) {
                                shouldContinue = NO; return;
                            }
                        }

                        uint32_t lenBE = 0;
                        if (!VCAMReadExact(fd, &lenBE, 4)) {
                            VCAMAppendMediaLog(@"read len failed/disconnected");
                            shouldContinue = NO; return;
                        }
                        uint32_t len = ntohl(lenBE);
                        if (len == 0 || len > 10 * 1024 * 1024) {
                            VCAMAppendMediaLog([NSString stringWithFormat:@"invalid len=%u", len]);
                            shouldContinue = NO; return;
                        }

                        NSMutableData *payload = [NSMutableData dataWithLength:len];
                        if (!VCAMReadExact(fd, payload.mutableBytes, len)) {
                            VCAMAppendMediaLog([NSString stringWithFormat:@"read payload failed len=%u", len]);
                            shouldContinue = NO; return;
                        }

                        CVPixelBufferRef pix = VCAMCreatePixelBufferFromJPEGData(payload);
                        if (pix) {
                            [self storeImageBuffer:(CVImageBufferRef)pix];
                            CVPixelBufferRelease(pix);
                        }
                    }
                }

                @synchronized (self) { [self closeSocketLocked]; }
                @synchronized (self) { if (!_running || generation != _generation) break; }
                [NSThread sleepForTimeInterval:2.0];
            }
        }
    }
}

- (void)storeImageBuffer:(CVImageBufferRef)imageBuffer {
    // 在这里同时把 CVPixelBuffer 转成 CGImage 存起来，供原地覆写路径使用
    // CGImage 路径：锁内存 → CGBitmapContextCreateImage → 解锁（不依赖 UIKit）
    CGImageRef cgImg = NULL;
    CVPixelBufferLockBaseAddress((CVPixelBufferRef)imageBuffer, kCVPixelBufferLock_ReadOnly);
    size_t w = CVPixelBufferGetWidth((CVPixelBufferRef)imageBuffer);
    size_t h = CVPixelBufferGetHeight((CVPixelBufferRef)imageBuffer);
    CGColorSpaceRef cs  = CGColorSpaceCreateDeviceRGB();
    CGContextRef    ctx = CGBitmapContextCreate(
        CVPixelBufferGetBaseAddress((CVPixelBufferRef)imageBuffer), w, h, 8,
        CVPixelBufferGetBytesPerRow((CVPixelBufferRef)imageBuffer), cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (ctx) { cgImg = CGBitmapContextCreateImage(ctx); CGContextRelease(ctx); }
    CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)imageBuffer, kCVPixelBufferLock_ReadOnly);

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, imageBuffer, &fmt) != noErr || !fmt) {
        if (cgImg) CGImageRelease(cgImg);
        return;
    }

    CMTime pts = CMClockGetTime(CMClockGetHostTimeClock());
    CMSampleTimingInfo timing = {
        .duration               = CMTimeMake(1, 30),
        .presentationTimeStamp  = pts,
        .decodeTimeStamp        = kCMTimeInvalid
    };

    CMSampleBufferRef sample = NULL;
    OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault, imageBuffer, fmt, &timing, &sample);
    CFRelease(fmt);
    if (st != noErr || !sample) {
        if (cgImg) CGImageRelease(cgImg);
        return;
    }

    VCAMSetSampleAttachments(sample);

    @synchronized (self) {
        if (_latestImageBuffer) { CFRelease(_latestImageBuffer); _latestImageBuffer = NULL; }
        _latestImageBuffer = (CVImageBufferRef)CFRetain(imageBuffer);
        if (_latestSample)      { CFRelease(_latestSample);      _latestSample      = NULL; }
        _latestSample = sample;
        if (_latestCGImage)     { CGImageRelease(_latestCGImage); _latestCGImage    = NULL; }
        _latestCGImage = cgImg; // 转让所有权（+1 已由 CGBitmapContextCreateImage 持有）
        _frameCount++;
        if (_frameCount <= 3 || (_frameCount % 120) == 0) {
            VCAMAppendMediaLog([NSString stringWithFormat:
                @"frame#=%llu size=%zux%zu", (unsigned long long)_frameCount, w, h]);
        }
    }
}

- (CMSampleBufferRef)copyLatestSampleBuffer {
    @synchronized (self) {
        if (_latestSample) { CFRetain(_latestSample); return _latestSample; }
        return NULL;
    }
}

- (CVImageBufferRef)copyLatestImageBuffer {
    @synchronized (self) {
        if (_latestImageBuffer) { CFRetain(_latestImageBuffer); return _latestImageBuffer; }
        return NULL;
    }
}

- (CGImageRef)copyLatestCGImage {
    @synchronized (self) {
        if (_latestCGImage) { CGImageRetain(_latestCGImage); return _latestCGImage; }
        return NULL;
    }
}

@end

// ─── VCAMService ──────────────────────────────────────────────────────────────
@implementation VCAMService {
    VCAMStreamReceiver *_receiver;
    BOOL        _enabled;
    NSString   *_host;
    int         _port;
    BOOL        _receiverStarted;
    int         _notifyToken;
}

+ (instancetype)shared {
    static VCAMService *inst = nil;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{ inst = [[VCAMService alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _receiver = [[VCAMStreamReceiver alloc] init];
        _host     = @"127.0.0.1";
        _port     = 7878;
    }
    return self;
}

- (NSDictionary *)defaultConfig { return @{@"enabled":@NO, @"host":@"127.0.0.1", @"port":@7878}; }

- (NSDictionary *)loadConfig {
    NSData *data = [NSData dataWithContentsOfFile:kVCAMConfigPath];
    if (data) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([obj isKindOfClass:[NSDictionary class]]) return obj;
    }
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:kVCAMConfigPath];
    return [plist isKindOfClass:[NSDictionary class]] ? plist : [self defaultConfig];
}

- (void)applyConfig {
    gVCAMLastManagerSyncAt = 0;
    [self syncAndCheckStatus];
}

- (void)syncAndCheckStatus {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if ((now - gVCAMLastManagerSyncAt) < 0.40) return;
    gVCAMLastManagerSyncAt = now;

    NSDictionary *cfg = [self loadConfig];
    id        enabledObj = [cfg[@"enabled"] respondsToSelector:@selector(boolValue)] ? cfg[@"enabled"] : @NO;
    BOOL      enabled = [enabledObj boolValue];
    NSString *host    = [cfg[@"host"] isKindOfClass:[NSString class]] ? cfg[@"host"] : @"127.0.0.1";
    host = [[host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
               stringByReplacingOccurrencesOfString:@"\u3002" withString:@"."];
    if (!host.length || [host isEqualToString:@"localhost"]) host = @"127.0.0.1";
    int port = [[cfg[@"port"] respondsToSelector:@selector(intValue)] ? cfg[@"port"] : @7878 intValue];
    if (port <= 0 || port > 65535) port = 7878;

    BOOL changed = NO;
    @synchronized (self) {
        changed = (_enabled != enabled) || (_port != port) || ![_host isEqualToString:host];
        _enabled = enabled; _host = [host copy]; _port = port;
        if (!_enabled) { [_receiver stop]; _receiverStarted = NO; }
        else           { [_receiver startWithHost:_host port:_port]; _receiverStarted = YES; }
    }

    if (changed || (gVCAMHookProbeCount % 180) == 0)
        VCAMAppendMediaLog([NSString stringWithFormat:
            @"sync enabled=%d host=%@ port=%d", enabled?1:0, host, port]);
}

- (void)startObserver {
    if (_notifyToken) return;
    __weak VCAMService *weak = self;
    notify_register_dispatch(kVCAMConfigNotify, &_notifyToken, dispatch_get_main_queue(), ^(int __unused t) {
        [weak applyConfig];
    });
}

- (void)ensureReceiverStartedIfNeeded { [self syncAndCheckStatus]; }

- (CMSampleBufferRef)copyLatestSampleBuffer {
    [self ensureReceiverStartedIfNeeded]; return [_receiver copyLatestSampleBuffer];
}
- (CVImageBufferRef)copyLatestImageBuffer {
    [self ensureReceiverStartedIfNeeded]; return [_receiver copyLatestImageBuffer];
}
- (CGImageRef)copyLatestCGImage {
    [self ensureReceiverStartedIfNeeded]; return [_receiver copyLatestCGImage];
}

@end

// ─── VCAMManager ──────────────────────────────────────────────────────────────
@implementation VCAMManager
+ (void)syncAndCheckStatus     { [[VCAMService shared] syncAndCheckStatus]; }
+ (CMSampleBufferRef)copyLatestSampleBuffer { return [[VCAMService shared] copyLatestSampleBuffer]; }
+ (CVImageBufferRef)copyLatestImageBuffer   { return [[VCAMService shared] copyLatestImageBuffer]; }
+ (CGImageRef)copyLatestCGImage             { return [[VCAMService shared] copyLatestCGImage]; }
@end

// ─── Constructor ──────────────────────────────────────────────────────────────
%ctor {
    @autoreleasepool {
        NSString *proc = NSProcessInfo.processInfo.processName ?: @"unknown";
        VCAMAppendProcessLog([NSString stringWithFormat:@"load process=%@", proc]);
        if (!gOrigCMSampleBufferGetImageBuffer) {
            MSHookFunction((void *)CMSampleBufferGetImageBuffer,
                           (void *)VCAMHookedCMSampleBufferGetImageBuffer,
                           (void **)&gOrigCMSampleBufferGetImageBuffer);
            VCAMAppendProcessLog([NSString stringWithFormat:@"hook CMSampleBufferGetImageBuffer process=%@", proc]);
        }
        [[VCAMService shared] startObserver];
        [[VCAMService shared] applyConfig];
        NSLog(@"[VCAMClone] loaded in process=%@", proc);
        notify_post(kVCAMMediaNotify);
    }
}
