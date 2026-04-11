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
- (CIImage *)copyLatestCIImage;   // ← 供原地覆写路径使用（已含 EXIF 方向校正）
@end

@interface VCAMService : NSObject
+ (instancetype)shared;
- (void)startObserver;
- (void)applyConfig;
- (void)syncAndCheckStatus;
- (void)ensureReceiverStartedIfNeeded;
- (CMSampleBufferRef)copyLatestSampleBuffer;
- (CVImageBufferRef)copyLatestImageBuffer;
- (CIImage *)copyLatestCIImage;
@end

@interface VCAMManager : NSObject
+ (void)syncAndCheckStatus;
+ (CMSampleBufferRef)copyLatestSampleBuffer;
+ (CVImageBufferRef)copyLatestImageBuffer;
+ (CIImage *)copyLatestCIImage;
@end

// ─── 共享 CIContext ───────────────────────────────────────────────────────────
static CIContext *VCAMSharedCIContext(void) {
    static CIContext *sCtx = nil;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{
        sCtx = [CIContext contextWithOptions:nil];
        VCAMAppendMediaLog(sCtx ? @"CIContext ok" : @"CIContext failed");
    });
    return sCtx;
}

// ─── JPEG → CVPixelBufferRef（修复：用 CIImage 处理 EXIF 方向）─────────────────
//
//  旧版用 CGImageCreateWithJPEGDataProvider，完全忽略 EXIF 方向，
//  导致竖屏 JPEG 被以横屏原始布局写入 buffer（旋转 90°）。
//  CIImage imageWithData: 自动读取 EXIF 并校正坐标系，
//  CIContext render:toCVPixelBuffer: 处理坐标翻转，输出正确朝向的 BGRA buffer。
// ─────────────────────────────────────────────────────────────────────────────
static CVPixelBufferRef VCAMCreatePixelBufferFromJPEGData(NSData *jpegData) {
    if (!jpegData.length) return NULL;

    CIImage *ci = [CIImage imageWithData:jpegData];  // 自动应用 EXIF 方向
    if (!ci) return NULL;

    size_t w = (size_t)ci.extent.size.width;
    size_t h = (size_t)ci.extent.size.height;
    if (w == 0 || h == 0) return NULL;

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey:              @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey:          @{},
        (id)kCVPixelBufferCGImageCompatibilityKey:         @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };

    CVPixelBufferRef buf = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &buf) != kCVReturnSuccess || !buf)
        return NULL;

    [VCAMSharedCIContext() render:ci toCVPixelBuffer:buf];
    return buf;
}

// ─── 原地覆写（核心修复）─────────────────────────────────────────────────────
//
//  旧版两条路径的问题：
//    路径 A (BGRA) — CGContextDrawImage 无坐标翻转，数据上下颠倒
//    路径 B (YUV)  — CIImage imageWithCGImage: 不处理 EXIF 方向
//
//  新版统一用 CIImage + CIContext：
//    • [CIImage imageWithData:] 自动含 EXIF 校正，朝向正确
//    • CIContext render:toCVPixelBuffer: 自动处理坐标系，支持任意格式
//    • 保留 Aspect-Fill 居中裁切逻辑
//    • lock/unlock ReadOnly 强制 IOSurface 同步，防录制 encoder 提前复用
// ─────────────────────────────────────────────────────────────────────────────
static BOOL VCAMReplacePixelsInPlace(CIImage *fakeCI, CVPixelBufferRef realBuf) {
    if (!fakeCI || !realBuf) return NO;

    CIContext *ctx = VCAMSharedCIContext();
    if (!ctx) return NO;

    size_t  dstW   = CVPixelBufferGetWidth(realBuf);
    size_t  dstH   = CVPixelBufferGetHeight(realBuf);
    CGRect  extent = fakeCI.extent;

    if (extent.size.width <= 0 || extent.size.height <= 0 || !dstW || !dstH) return NO;

    static uint64_t sReplaceCount = 0;
    sReplaceCount++;
    if (sReplaceCount <= 5 || (sReplaceCount % 300) == 0)
        VCAMAppendMediaLog([NSString stringWithFormat:
            @"replace#=%llu src=%.0fx%.0f dst=%zux%zu fmt=%u",
            (unsigned long long)sReplaceCount,
            extent.size.width, extent.size.height,
            dstW, dstH,
            (unsigned)CVPixelBufferGetPixelFormatType(realBuf)]);

    // 1. Aspect-Fill：等比放大到覆盖目标
    CGFloat fillScale = MAX((CGFloat)dstW / extent.size.width,
                            (CGFloat)dstH / extent.size.height);
    CIImage *scaled   = [fakeCI imageByApplyingTransform:CGAffineTransformMakeScale(fillScale, fillScale)];

    // 2. 居中裁切到目标尺寸
    CGRect scaledExt  = scaled.extent;
    CGRect cropRect   = CGRectMake(
        scaledExt.origin.x + (scaledExt.size.width  - (CGFloat)dstW) * 0.5,
        scaledExt.origin.y + (scaledExt.size.height - (CGFloat)dstH) * 0.5,
        (CGFloat)dstW, (CGFloat)dstH);
    CIImage *cropped   = [scaled imageByCroppingToRect:cropRect];

    // 3. 平移到 (0,0) origin，确保 render:toCVPixelBuffer: 精确填满整个 buffer
    CIImage *positioned = [cropped imageByApplyingTransform:
        CGAffineTransformMakeTranslation(-cropRect.origin.x, -cropRect.origin.y)];

    // 4. 渲染到真实 buffer（支持 BGRA/NV12/420v/420f 等任意格式）
    [ctx render:positioned toCVPixelBuffer:realBuf];

    // 5. IOSurface 同步：等 GPU 写完再返回，防录制线程提前复用
    CVPixelBufferLockBaseAddress(realBuf,   kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(realBuf, kCVPixelBufferLock_ReadOnly);

    if (sReplaceCount <= 5) VCAMAppendMediaLog(@"replace ok");
    return YES;
}

// ─── The actual hook function ─────────────────────────────────────────────────
static CVImageBufferRef VCAMHookedCMSampleBufferGetImageBuffer(CMSampleBufferRef sampleBuffer) {
    if (!gOrigCMSampleBufferGetImageBuffer) return NULL;
    [VCAMManager syncAndCheckStatus];

    CVImageBufferRef originalImage = gOrigCMSampleBufferGetImageBuffer(sampleBuffer);
    gVCAMHookProbeCount++;

    if (gVCAMHookProbeCount <= 5 || (gVCAMHookProbeCount % 300) == 0)
        VCAMAppendMediaLog([NSString stringWithFormat:
            @"hook probe=%llu origImg=%s",
            (unsigned long long)gVCAMHookProbeCount,
            originalImage ? "yes" : "null"]);

    if (originalImage) {
        CIImage *fakeCI = [VCAMManager copyLatestCIImage];  // 已含 EXIF 校正
        if (fakeCI) {
            VCAMReplacePixelsInPlace(fakeCI, (CVPixelBufferRef)originalImage);
        }
    }

    return originalImage;
}

// ─── VCAMStreamReceiver (MJPEG) ───────────────────────────────────────────────
@interface VCAMStreamReceiver ()
- (void)connectLoop:(NSNumber *)generationObj;
- (void)resetStreamStateLocked;
- (void)storeImageBuffer:(CVImageBufferRef)imageBuffer withCIImage:(CIImage *)ci;
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
    CIImage           *_latestCIImage;   // ← 替代旧版 CGImageRef，已含 EXIF 方向校正
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
    _latestCIImage = nil;
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

                        // ── 用 CIImage 解码 JPEG（自动处理 EXIF 方向）─────────────────
                        CIImage *ci = [CIImage imageWithData:payload];

                        // 同时构建 CVPixelBuffer + CMSampleBuffer 供 copyLatestSampleBuffer 使用
                        CVPixelBufferRef pix = VCAMCreatePixelBufferFromJPEGData(payload);
                        if (pix) {
                            [self storeImageBuffer:(CVImageBufferRef)pix withCIImage:ci];
                            CVPixelBufferRelease(pix);
                        } else if (ci) {
                            // 无法建 PixelBuffer 时至少存 CIImage
                            @synchronized (self) { _latestCIImage = ci; }
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

- (void)storeImageBuffer:(CVImageBufferRef)imageBuffer withCIImage:(CIImage *)ci {
    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, imageBuffer, &fmt) != noErr || !fmt) {
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
    if (st != noErr || !sample) return;

    VCAMSetSampleAttachments(sample);

    @synchronized (self) {
        if (_latestImageBuffer) { CFRelease(_latestImageBuffer); _latestImageBuffer = NULL; }
        _latestImageBuffer = (CVImageBufferRef)CFRetain(imageBuffer);
        if (_latestSample)      { CFRelease(_latestSample);      _latestSample      = NULL; }
        _latestSample = sample;
        _latestCIImage = ci;    // 已含 EXIF 校正，供 hook 路径使用

        _frameCount++;
        if (_frameCount <= 3 || (_frameCount % 120) == 0) {
            size_t w = CVPixelBufferGetWidth((CVPixelBufferRef)imageBuffer);
            size_t h = CVPixelBufferGetHeight((CVPixelBufferRef)imageBuffer);
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

- (CIImage *)copyLatestCIImage {
    @synchronized (self) {
        return _latestCIImage;  // ARC 持有，无需手动 retain
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
- (CIImage *)copyLatestCIImage {
    [self ensureReceiverStartedIfNeeded]; return [_receiver copyLatestCIImage];
}

@end

// ─── VCAMManager ──────────────────────────────────────────────────────────────
@implementation VCAMManager
+ (void)syncAndCheckStatus        { [[VCAMService shared] syncAndCheckStatus]; }
+ (CMSampleBufferRef)copyLatestSampleBuffer { return [[VCAMService shared] copyLatestSampleBuffer]; }
+ (CVImageBufferRef)copyLatestImageBuffer   { return [[VCAMService shared] copyLatestImageBuffer]; }
+ (CIImage *)copyLatestCIImage              { return [[VCAMService shared] copyLatestCIImage]; }
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
