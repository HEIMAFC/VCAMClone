#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <notify.h>
#import <math.h>
#import <dlfcn.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <sys/types.h>
#import <fcntl.h>
#import <unistd.h>

static NSString *const kVCAMConfigPath           = @"/var/tmp/vcam_stream.conf";
static NSString *const kVCAMSpringBoardMarkerPath = @"/var/tmp/vcam_springboard_loaded.txt";
static NSString *const kVCAMSBEventLogPath        = @"/var/tmp/vcam_sb_events.log";
static const char *kVCAMConfigNotify  = "com.vcam.stream.config";
static const char *kVCAMMediaNotify   = "com.vcam.media.stream.recv";
static const char *kVCAMReloadNotify  = "com.vcam.notify.reload";
static const char *kVCAMShowUINotify  = "com.vcam.showui";
static const char *kVCAMShowUIAckNotify        = "com.vcam.showui.ack";
static const char *kVCAMColorPickerToggleNotify = "com.vcam.colorpicker.toggle";
static const int   kVCAMColorPickerPort         = 7879;

static BOOL           gProcessIsSpringBoard      = NO;
static BOOL           gIsPresentingControlUI     = NO;
static CFTimeInterval gLastVolumeUpTime          = 0;
static CFTimeInterval gLastVolumeDownTime        = 0;
static CFTimeInterval gLastTriggerTime           = 0;
static float          gLastObservedVolume        = -1.0f;
static float          gLastPolledVolume          = -1.0f;
static id             gVolumeObserver            = nil;
static dispatch_source_t gVolumePollTimer        = nil;
static UIWindow      *gControlWindow             = nil;
static int            gShowUINotifyToken         = 0;
static BOOL           gDarwinVolumeObserverStarted = NO;
static BOOL           gVCAMCameraSessionRunning  = NO;
static CFTimeInterval gVCAMLastSBManagerSyncAt   = 0;

static dispatch_queue_t VCAMSBControlQueue(void) {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{
        queue = dispatch_queue_create("com.vcam.clone.sb.control", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void VCAMAppendSBLog(NSString *line) {
    if (!line.length) return;
    NSString *entry = [NSString stringWithFormat:@"%.3f %@\n", CFAbsoluteTimeGetCurrent(), line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kVCAMSBEventLogPath];
    if (!fh) { [entry writeToFile:kVCAMSBEventLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    @try { [fh seekToEndOfFile]; [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]]; }
    @catch (__unused NSException *e) {}
    @try { [fh closeFile]; } @catch (__unused NSException *e) {}
}

static NSDictionary *VCAMLoadRawConfig(void) {
    NSDictionary *fallback = @{@"enabled":@NO, @"host":@"127.0.0.1", @"port":@7878};
    NSData *data = [NSData dataWithContentsOfFile:kVCAMConfigPath];
    if (data.length) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([obj isKindOfClass:[NSDictionary class]]) return obj;
    }
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:kVCAMConfigPath];
    return [plist isKindOfClass:[NSDictionary class]] ? plist : fallback;
}

static BOOL VCAMSaveRawConfig(BOOL enabled, NSString *host, int port) {
    NSString *h = [host isKindOfClass:[NSString class]] ? host : @"";
    h = [[h stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
             stringByReplacingOccurrencesOfString:@"\u3002" withString:@"."];
    if (!h.length || [h isEqualToString:@"localhost"]) h = @"127.0.0.1";
    if (port <= 0 || port > 65535) port = 7878;

    NSDictionary *cfg = @{@"enabled":@(enabled), @"host":h, @"port":@(port)};
    NSData *json = [NSJSONSerialization dataWithJSONObject:cfg options:0 error:nil];
    BOOL ok = json.length ? [json writeToFile:kVCAMConfigPath atomically:YES]
                          : [cfg  writeToFile:kVCAMConfigPath atomically:YES];
    if (ok) {
        notify_post(kVCAMConfigNotify);
        notify_post(kVCAMMediaNotify);
        notify_post(kVCAMReloadNotify);
    }
    VCAMAppendSBLog([NSString stringWithFormat:@"save config ok=%d enabled=%d host=%@ port=%d",
                     ok?1:0, enabled?1:0, h, port]);
    return ok;
}

static UIWindowScene *VCAMFirstWindowScene(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;
    UIWindowScene *fallback = nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        if (!fallback) fallback = ws;
    }
    return fallback;
}

// ─── Volume event helpers ─────────────────────────────────────────────────────
static BOOL VCAMEventKeyCodeIs(id event, NSInteger code) {
    for (NSString *k in @[@"keyCode", @"_keyCode", @"usage", @"_usage"]) {
        @try {
            id v = [event valueForKey:k];
            if ([v respondsToSelector:@selector(integerValue)] && [v integerValue] == code) return YES;
        } @catch (__unused NSException *e) {}
    }
    return NO;
}
static BOOL VCAMEventLooksVolumeUp(id e) {
    if (!e) return NO;
    if (VCAMEventKeyCodeIs(e, 0xE9) || VCAMEventKeyCodeIs(e, 233)) return YES;
    NSString *d = [[e description] lowercaseString];
    return [d containsString:@"volumeup"] || [d containsString:@"volume_up"]
        || ([d containsString:@"volume"] && [d containsString:@"up"]);
}
static BOOL VCAMEventLooksVolumeDown(id e) {
    if (!e) return NO;
    if (VCAMEventKeyCodeIs(e, 0xEA) || VCAMEventKeyCodeIs(e, 234)) return YES;
    NSString *d = [[e description] lowercaseString];
    return [d containsString:@"volumedown"] || [d containsString:@"volume_down"]
        || ([d containsString:@"volume"] && [d containsString:@"down"]);
}

// ─── TCP recv helper ──────────────────────────────────────────────────────────
static BOOL VCAMReadExactSB(int fd, void *buffer, size_t length) {
    uint8_t *ptr = (uint8_t *)buffer;
    size_t done = 0;
    while (done < length) {
        ssize_t r = recv(fd, ptr + done, length - done, 0);
        if (r <= 0) return NO;
        done += (size_t)r;
    }
    return YES;
}

// ─── Connect with timeout ─────────────────────────────────────────────────────
static int VCAMSBConnectWithTimeout(const char *host, int port, int timeoutSec) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len    = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port   = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) { close(fd); errno = EINVAL; return -1; }

    int r = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (r != 0 && errno != EINPROGRESS) { int e = errno; close(fd); errno = e; return -1; }
    if (r != 0) {
        fd_set wfds; FD_ZERO(&wfds); FD_SET(fd, &wfds);
        struct timeval tv = { timeoutSec > 0 ? timeoutSec : 2, 0 };
        int sel = select(fd + 1, NULL, &wfds, NULL, &tv);
        if (sel <= 0) { int e = (sel == 0) ? ETIMEDOUT : errno; close(fd); errno = e; return -1; }
        int soErr = 0; socklen_t soLen = sizeof(soErr);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soLen) != 0 || soErr != 0) {
            int e = soErr ? soErr : errno; close(fd); errno = e; return -1;
        }
    }
    if (flags >= 0) fcntl(fd, F_SETFL, flags);
    return fd;
}

// ─── JPEG → CVPixelBufferRef ──────────────────────────────────────────────────
// 修复：旧版用 CGContextDrawImage(img.CGImage) 跳过了 UIImage.imageOrientation，
// 导致 EXIF 竖屏照片以横屏原始像素写入 buffer，SpringBoard 预览画面旋转 90°。
// 新版：翻转坐标系 + UIGraphicsPushContext + [img drawInRect:]，自动处理方向。
static CVPixelBufferRef VCAMSBCreatePixelBufferFromJPEGData(NSData *jpegData) {
    UIImage *img = [UIImage imageWithData:jpegData];
    if (!img || img.size.width <= 0 || img.size.height <= 0) return NULL;

    size_t w = (size_t)img.size.width, h = (size_t)img.size.height;
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

    CVPixelBufferLockBaseAddress(buf, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buf), w, h, 8,
        CVPixelBufferGetBytesPerRow(buf), cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (ctx) {
        // 翻转为 UIKit 坐标系（top-left），使 drawInRect: 正确处理 imageOrientation
        CGContextTranslateCTM(ctx, 0, (CGFloat)h);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        UIGraphicsPushContext(ctx);
        [img drawInRect:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h)];
        UIGraphicsPopContext();
        CGContextRelease(ctx);
    }
    CVPixelBufferUnlockBaseAddress(buf, 0);
    return buf;
}

static void VCAMSBSetSampleAttachments(CMSampleBufferRef sample) {
    if (!sample) return;
    CFArrayRef arr = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
    if (!arr || CFArrayGetCount(arr) <= 0) return;
    CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(arr, 0);
    if (!dict) return;
    CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    CFDictionaryRemoveValue(dict, kCMSampleAttachmentKey_NotSync);
}

// ─── Forward declarations ─────────────────────────────────────────────────────
@class VCAMStreamPreviewPump;

@interface VCAMManager : NSObject
+ (NSDictionary *)loadStreamConfig;
+ (BOOL)saveStreamConfigEnabled:(BOOL)enabled host:(NSString *)host port:(int)port;
+ (void)clearStreamConfig;
+ (void)setCameraSessionRunning:(BOOL)running;
+ (void)syncAndCheckStatus;
@end

@interface VCAMStreamPreviewPump : NSObject
@property (nonatomic, readonly, getter=isAttached) BOOL attached;
+ (instancetype)shared;
- (void)attachToPreviewLayer:(AVSampleBufferDisplayLayer *)layer;
- (void)detach;
@end

// ─── VCAMSBPreviewReceiver (MJPEG) ────────────────────────────────────────────
@interface VCAMSBPreviewReceiver : NSObject
+ (instancetype)shared;
- (void)startWithHost:(NSString *)host port:(int)port;
- (void)stop;
- (CMSampleBufferRef)copyLatestSampleBuffer;
- (NSDictionary *)statusSnapshot;
@end

@interface VCAMSBPreviewReceiver ()
- (void)connectLoop:(NSNumber *)generationObj;
- (void)closeSocketLocked;
- (void)resetStreamStateLocked;
- (void)storeImageBuffer:(CVImageBufferRef)imageBuffer;
@end

@implementation VCAMSBPreviewReceiver {
    NSString      *_host;
    int            _port;
    BOOL           _running;
    BOOL           _connected;
    int            _socketFD;
    NSThread      *_loopThread;
    NSInteger      _generation;

    CMSampleBufferRef  _latestSample;
    uint64_t           _latestSampleSeq;
    uint64_t           _frameCount;
    CFTimeInterval     _lastFrameAt;
    NSString          *_lastError;
}

+ (instancetype)shared {
    static VCAMSBPreviewReceiver *inst = nil;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{ inst = [[VCAMSBPreviewReceiver alloc] init]; });
    return inst;
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
    if (_socketFD >= 0) { shutdown(_socketFD, SHUT_RDWR); close(_socketFD); _socketFD = -1; }
}

- (void)startWithHost:(NSString *)host port:(int)port {
    NSString *h = [host isKindOfClass:[NSString class]] ? host : @"";
    h = [h stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!h.length || port <= 0 || port > 65535) return;

    @synchronized (self) {
        if (_running && [_host isEqualToString:h] && _port == port) return;
        _running = NO; _generation++;
        [self closeSocketLocked];
        _host = [h copy]; _port = port; _running = YES; _connected = NO;
        _lastError = @"\u8fde\u63a5\u4e2d";
        [self resetStreamStateLocked];

        NSInteger gen = _generation;
        _loopThread = [[NSThread alloc] initWithTarget:self selector:@selector(connectLoop:) object:@(gen)];
        _loopThread.name = @"VCAMCloneSB.PreviewLoop";
        [_loopThread start];
    }
    VCAMAppendSBLog([NSString stringWithFormat:@"preview start host=%@ port=%d", h, port]);
}

- (void)stop {
    @synchronized (self) {
        _running = NO; _connected = NO; _generation++;
        [self closeSocketLocked]; _lastError = nil;
        [self resetStreamStateLocked];
    }
    VCAMAppendSBLog(@"preview stop");
}

- (void)resetStreamStateLocked {
    _frameCount = 0; _lastFrameAt = 0;
    if (_latestSample) { CFRelease(_latestSample); _latestSample = NULL; }
    _latestSampleSeq = 0;
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

                int fd = VCAMSBConnectWithTimeout(host.UTF8String, port, 2);
                if (fd < 0) {
                    @synchronized (self) {
                        if (_running && generation == _generation) {
                            _connected = NO;
                            _lastError = [NSString stringWithFormat:@"\u8fde\u63a5\u5931\u8d25:%d", errno];
                        }
                    }
                    [NSThread sleepForTimeInterval:1.2]; continue;
                }
                VCAMAppendSBLog([NSString stringWithFormat:@"preview connected %@:%d", host, port]);

                @synchronized (self) {
                    if (!_running || generation != _generation) { close(fd); break; }
                    _socketFD = fd; _connected = YES; _lastError = nil;
                }

                NSString *disconnectReason = @"\u65ad\u5f00";
                BOOL shouldContinue = YES;
                while (shouldContinue) {
                    @autoreleasepool {
                        @synchronized (self) {
                            if (!_running || generation != _generation) {
                                disconnectReason = @"\u505c\u6b62\u4e2d";
                                shouldContinue = NO; return;
                            }
                        }

                        uint32_t lenBE = 0;
                        if (!VCAMReadExactSB(fd, &lenBE, sizeof(lenBE))) {
                            disconnectReason = @"\u8bfb\u53d6\u5934\u5931\u8d25";
                            shouldContinue = NO; return;
                        }
                        uint32_t len = ntohl(lenBE);
                        if (len == 0 || len > 10 * 1024 * 1024) {
                            disconnectReason = [NSString stringWithFormat:@"\u957f\u5ea6\u5f02\u5e38:%u", len];
                            shouldContinue = NO; return;
                        }

                        NSMutableData *payload = [NSMutableData dataWithLength:len];
                        if (!VCAMReadExactSB(fd, payload.mutableBytes, len)) {
                            disconnectReason = @"\u8bfb\u53d6\u5e27\u5931\u8d25";
                            shouldContinue = NO; return;
                        }

                        CVPixelBufferRef pix = VCAMSBCreatePixelBufferFromJPEGData(payload);
                        if (pix) {
                            [self storeImageBuffer:(CVImageBufferRef)pix];
                            CVPixelBufferRelease(pix);
                        }
                    }
                }

                @synchronized (self) {
                    [self closeSocketLocked]; _connected = NO;
                    if (_running && generation == _generation) _lastError = disconnectReason;
                }
                VCAMAppendSBLog([NSString stringWithFormat:@"preview disconnect reason=%@", disconnectReason]);
                [NSThread sleepForTimeInterval:0.8];
            }
        }
    }
}

- (void)storeImageBuffer:(CVImageBufferRef)imageBuffer {
    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, imageBuffer, &fmt) != noErr || !fmt)
        return;

    CMTime pts = CMClockGetTime(CMClockGetHostTimeClock());
    CMSampleTimingInfo timing = {
        .duration              = CMTimeMake(1, 30),
        .presentationTimeStamp = pts,
        .decodeTimeStamp       = kCMTimeInvalid
    };
    CMSampleBufferRef sample = NULL;
    OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, imageBuffer, fmt, &timing, &sample);
    CFRelease(fmt);
    if (st != noErr || !sample) return;

    VCAMSBSetSampleAttachments(sample);

    @synchronized (self) {
        if (_latestSample) CFRelease(_latestSample);
        _latestSample = sample;
        _latestSampleSeq++; _frameCount++;
        _lastFrameAt = CFAbsoluteTimeGetCurrent(); _lastError = nil;
        if (_frameCount <= 3 || (_frameCount % 150) == 0) {
            size_t w = CVPixelBufferGetWidth((CVPixelBufferRef)imageBuffer);
            size_t h = CVPixelBufferGetHeight((CVPixelBufferRef)imageBuffer);
            VCAMAppendSBLog([NSString stringWithFormat:@"preview frame#=%llu size=%zux%zu",
                             (unsigned long long)_frameCount, w, h]);
        }
    }
}

- (CMSampleBufferRef)copyLatestSampleBuffer {
    @synchronized (self) {
        if (_latestSample) { CFRetain(_latestSample); return _latestSample; }
        return NULL;
    }
}

- (NSDictionary *)statusSnapshot {
    @synchronized (self) {
        double ageMs = (_lastFrameAt > 0) ? MAX(0.0, (CFAbsoluteTimeGetCurrent() - _lastFrameAt) * 1000.0) : -1.0;
        return @{
            @"running":    @(_running),
            @"connected":  @(_connected),
            @"has_frame":  @(_latestSample != NULL),
            @"sample_seq": @((unsigned long long)_latestSampleSeq),
            @"age_ms":     @(ageMs),
            @"error":      _lastError ?: @"",
        };
    }
}

@end

// ─── VCAMStreamPreviewPump ────────────────────────────────────────────────────
@interface VCAMStreamPreviewPump ()
- (void)_ensureDisplayLink;
- (void)_tick:(CADisplayLink *)link;
@end

@implementation VCAMStreamPreviewPump {
    CADisplayLink                *_displayLink;
    __weak AVSampleBufferDisplayLayer *_previewLayer;
    uint64_t                      _lastDisplayedSeq;
}

+ (instancetype)shared {
    static VCAMStreamPreviewPump *inst = nil;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{ inst = [[VCAMStreamPreviewPump alloc] init]; });
    return inst;
}

- (BOOL)isAttached { return _previewLayer != nil; }

- (void)_ensureDisplayLink {
    if (_displayLink) return;
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(_tick:)];
    _displayLink.preferredFramesPerSecond = 15;
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    _displayLink.paused = YES;
}

- (void)attachToLayer:(CALayer *)layer {
    if ([layer isKindOfClass:[AVSampleBufferDisplayLayer class]])
        [self attachToPreviewLayer:(AVSampleBufferDisplayLayer *)layer];
}

- (void)attachToPreviewLayer:(AVSampleBufferDisplayLayer *)layer {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _ensureDisplayLink];
        _previewLayer = layer;
        _lastDisplayedSeq = 0;
        if (_previewLayer) {
            if ([_previewLayer respondsToSelector:@selector(flushAndRemoveImage)])
                [_previewLayer flushAndRemoveImage];
            else [_previewLayer flush];
        }
        _displayLink.paused = (_previewLayer == nil);
        gVCAMLastSBManagerSyncAt = 0;
        [VCAMManager syncAndCheckStatus];
    });
}

- (void)detach {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_previewLayer) {
            if ([_previewLayer respondsToSelector:@selector(flushAndRemoveImage)])
                [_previewLayer flushAndRemoveImage];
            else [_previewLayer flush];
        }
        _previewLayer = nil; _lastDisplayedSeq = 0;
        if (_displayLink) _displayLink.paused = YES;
        gVCAMLastSBManagerSyncAt = 0;
        [VCAMManager syncAndCheckStatus];
    });
}

- (void)_tick:(CADisplayLink *)link {
    AVSampleBufferDisplayLayer *layer = _previewLayer;
    if (!layer) { link.paused = YES; return; }

    NSDictionary *status = [[VCAMSBPreviewReceiver shared] statusSnapshot];
    uint64_t seq = [status[@"sample_seq"] unsignedLongLongValue];
    if (seq == 0 || seq == _lastDisplayedSeq) return;

    CMSampleBufferRef sample = [[VCAMSBPreviewReceiver shared] copyLatestSampleBuffer];
    if (!sample) return;

    if (layer.status == AVQueuedSampleBufferRenderingStatusFailed && layer.requiresFlushToResumeDecoding)
        [layer flush];
    if (layer.isReadyForMoreMediaData) {
        [layer enqueueSampleBuffer:sample];
        _lastDisplayedSeq = seq;
    } else if (layer.requiresFlushToResumeDecoding) {
        [layer flush];
    }
    CFRelease(sample);
}

@end

// ─── VCAMColorPickerSender ────────────────────────────────────────────────────
//  以 15 FPS 抓取屏幕中心 10×10 区域平均 RGB，通过独立 TCP 连接推送到 PC 7879 端口。
//  PC 实时将背景色更新为相同颜色，形成光学闭环以对抗活体检测屏幕闪色机制。
//
//  屏幕截图优先使用私有 API UIGetScreenImage（可抓全屏含前台 App），
//  不可用时回退到 drawViewHierarchyInRect:（仅限 SpringBoard 自身 UI）。
// ─────────────────────────────────────────────────────────────────────────────
// 运行时动态查找私有 API（避免链接期 undefined symbol）
typedef UIImage *(*_VCAMUIGetScreenImageFn)(void);
static _VCAMUIGetScreenImageFn _VCAMUIGetScreenImage(void) {
    static _VCAMUIGetScreenImageFn fn = NULL;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{ fn = (_VCAMUIGetScreenImageFn)dlsym(RTLD_DEFAULT, "UIGetScreenImage"); });
    return fn;
}

@interface VCAMColorPickerSender : NSObject
+ (instancetype)shared;
- (void)toggle;
@property (nonatomic, readonly) BOOL running;
@end

@implementation VCAMColorPickerSender {
    CADisplayLink    *_displayLink;
    dispatch_queue_t  _tcpQueue;
    int               _sockFD;
    BOOL              _running;
    NSString         *_host;
}

+ (instancetype)shared {
    static VCAMColorPickerSender *inst = nil;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{ inst = [[VCAMColorPickerSender alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sockFD   = -1;
        _tcpQueue = dispatch_queue_create("com.vcam.colorpicker.tcp", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)running { return _running; }

- (void)toggle {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_running) [self _stop];
        else                [self _start];
    });
}

- (void)_start {
    if (_running) return;
    NSDictionary *cfg = VCAMLoadRawConfig();
    NSString *host = [cfg[@"host"] isKindOfClass:[NSString class]] ? cfg[@"host"] : @"127.0.0.1";
    host = [[host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
               stringByReplacingOccurrencesOfString:@"\u3002" withString:@"."];
    if (!host.length || [host isEqualToString:@"localhost"]) host = @"127.0.0.1";
    _host    = [host copy];
    _running = YES;

    if (!_displayLink) {
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(_tick:)];
        _displayLink.preferredFramesPerSecond = 15;
    }
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    _displayLink.paused = NO;
    VCAMAppendSBLog([NSString stringWithFormat:@"colorpicker start host=%@ port=%d", _host, kVCAMColorPickerPort]);
}

- (void)_stop {
    if (!_running) return;
    _running = NO;
    _displayLink.paused = YES;
    [_displayLink invalidate];
    _displayLink = nil;
    dispatch_async(_tcpQueue, ^{
        if (self->_sockFD >= 0) {
            shutdown(self->_sockFD, SHUT_RDWR);
            close(self->_sockFD);
            self->_sockFD = -1;
        }
    });
    VCAMAppendSBLog(@"colorpicker stop");
}

// ─── 截屏 → 平均 RGB ──────────────────────────────────────────────────────────
- (void)_tick:(CADisplayLink *)link {
    if (!_running) { link.paused = YES; return; }

    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    CGFloat cx      = (screenW - 10.0) / 2.0;
    CGFloat cy      = 100.0;  // 距顶部 100pt，避开刘海/状态栏

    uint8_t pixels[10 * 10 * 4];
    memset(pixels, 0, sizeof(pixels));

    // 优先：UIGetScreenImage 抓取全屏合成图（含前台 App），运行时 dlsym 查找
    BOOL captured = NO;
    _VCAMUIGetScreenImageFn fnGetScreen = _VCAMUIGetScreenImage();
    if (fnGetScreen) {
        UIImage *full = fnGetScreen();
        if (full && full.CGImage) {
            CGFloat scale = full.scale > 0 ? full.scale : 1.0;
            CGRect cropPx = CGRectMake(cx * scale, cy * scale, 10 * scale, 10 * scale);
            CGImageRef cropped = CGImageCreateWithImageInRect(full.CGImage, cropPx);
            if (cropped) {
                CGColorSpaceRef cs  = CGColorSpaceCreateDeviceRGB();
                CGContextRef    ctx = CGBitmapContextCreate(pixels, 10, 10, 8, 40, cs,
                    kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast);
                CGColorSpaceRelease(cs);
                if (ctx) { CGContextDrawImage(ctx, CGRectMake(0,0,10,10), cropped); CGContextRelease(ctx); captured = YES; }
                CGImageRelease(cropped);
            }
        }
    }

    // 回退：从 SpringBoard 窗口层渲染（仅 SB 自身 UI，无法抓前台 App）
    if (!captured) {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(10, 10), YES, 1.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        if (ctx) {
            CGContextTranslateCTM(ctx, -cx, -cy);
            // 使用 UIWindowScene.windows（iOS 13+ 正式 API，规避 UIApplication.windows 的 iOS 15 弃用警告）
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows)
                    [w drawViewHierarchyInRect:CGRectMake(0, 0, screenW, screenH) afterScreenUpdates:NO];
            }
        }
        UIImage *snap = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (snap && snap.CGImage) {
            CGColorSpaceRef cs  = CGColorSpaceCreateDeviceRGB();
            CGContextRef    ctx2 = CGBitmapContextCreate(pixels, 10, 10, 8, 40, cs,
                kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast);
            CGColorSpaceRelease(cs);
            if (ctx2) { CGContextDrawImage(ctx2, CGRectMake(0,0,10,10), snap.CGImage); CGContextRelease(ctx2); captured = YES; }
        }
    }

    if (!captured) return;

    // 计算 100 像素平均 RGB
    uint32_t sumR = 0, sumG = 0, sumB = 0;
    for (int i = 0; i < 100; i++) {
        sumR += pixels[i * 4 + 0];
        sumG += pixels[i * 4 + 1];
        sumB += pixels[i * 4 + 2];
    }
    uint8_t r = (uint8_t)(sumR / 100);
    uint8_t g = (uint8_t)(sumG / 100);
    uint8_t b = (uint8_t)(sumB / 100);

    // JSON 推送（在 TCP 线程执行，不阻塞主线程）
    NSString *json = [NSString stringWithFormat:@"{\"r\":%u,\"g\":%u,\"b\":%u}\n",
                      (unsigned)r, (unsigned)g, (unsigned)b];
    NSData *payload  = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSString *host   = [_host copy];

    dispatch_async(_tcpQueue, ^{
        [self _ensureConnected:host];
        [self _sendData:payload];
    });
}

// ─── TCP 工具 ─────────────────────────────────────────────────────────────────
- (void)_ensureConnected:(NSString *)host {
    if (_sockFD >= 0) return;
    _sockFD = VCAMSBConnectWithTimeout(host.UTF8String, kVCAMColorPickerPort, 2);
    if (_sockFD < 0) {
        VCAMAppendSBLog([NSString stringWithFormat:
            @"colorpicker connect failed host=%@ port=%d errno=%d", host, kVCAMColorPickerPort, errno]);
    } else {
        int opt = 1;
        setsockopt(_sockFD, SOL_SOCKET, SO_NOSIGPIPE, &opt, sizeof(opt));
        VCAMAppendSBLog([NSString stringWithFormat:
            @"colorpicker connected host=%@ port=%d", host, kVCAMColorPickerPort]);
    }
}

- (void)_sendData:(NSData *)data {
    if (!data.length || _sockFD < 0) return;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    size_t total = data.length, sent = 0;
    while (sent < total) {
        ssize_t n = send(_sockFD, bytes + sent, total - sent, 0);
        if (n <= 0) { close(_sockFD); _sockFD = -1; break; }
        sent += (size_t)n;
    }
}

@end

// ─── VCAMManager ──────────────────────────────────────────────────────────────
@implementation VCAMManager

+ (NSDictionary *)loadStreamConfig { return VCAMLoadRawConfig(); }

+ (BOOL)saveStreamConfigEnabled:(BOOL)enabled host:(NSString *)host port:(int)port {
    BOOL ok = VCAMSaveRawConfig(enabled, host, port);
    gVCAMLastSBManagerSyncAt = 0;
    [self syncAndCheckStatus];
    return ok;
}

+ (void)clearStreamConfig { [self saveStreamConfigEnabled:NO host:@"127.0.0.1" port:7878]; }

+ (void)setCameraSessionRunning:(BOOL)running {
    gVCAMCameraSessionRunning = running;
    gVCAMLastSBManagerSyncAt = 0;
    [self syncAndCheckStatus];
}

+ (void)syncAndCheckStatus {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if ((now - gVCAMLastSBManagerSyncAt) < 0.40) return;
    gVCAMLastSBManagerSyncAt = now;

    NSDictionary *cfg = VCAMLoadRawConfig();
    id enabledObj = [cfg[@"enabled"] respondsToSelector:@selector(boolValue)] ? cfg[@"enabled"] : @NO;
    BOOL enabled  = [enabledObj boolValue];
    NSString *host = [cfg[@"host"] isKindOfClass:[NSString class]] ? cfg[@"host"] : @"127.0.0.1";
    host = [[host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
               stringByReplacingOccurrencesOfString:@"\u3002" withString:@"."];
    if (!host.length || [host isEqualToString:@"localhost"]) host = @"127.0.0.1";
    int port = [[cfg[@"port"] respondsToSelector:@selector(intValue)] ? cfg[@"port"] : @7878 intValue];
    if (port <= 0 || port > 65535) port = 7878;

    BOOL previewAttached = [VCAMStreamPreviewPump shared].attached;
    NSString *hostCopy = [host copy];
    dispatch_async(VCAMSBControlQueue(), ^{
        if (previewAttached)
            [[VCAMSBPreviewReceiver shared] startWithHost:hostCopy port:port];
        else
            [[VCAMSBPreviewReceiver shared] stop];
    });

    VCAMAppendSBLog([NSString stringWithFormat:
        @"sync enabled=%d preview=%d cameraRunning=%d host=%@ port=%d",
        enabled?1:0, previewAttached?1:0, gVCAMCameraSessionRunning?1:0, host, port]);
}

@end

// ─── Control UI ───────────────────────────────────────────────────────────────
@interface VCAMControlViewController : UIViewController <UITextFieldDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UITextField *hostField;
@property (nonatomic, strong) UILabel     *statusLabel;
@property (nonatomic, strong) UIView      *previewHostView;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *previewLayer;
@property (nonatomic, strong) UILabel     *previewHintLabel;
@property (nonatomic, strong) NSTimer     *previewTimer;
@property (nonatomic, strong) UIView      *panelView;
@property (nonatomic, assign) BOOL         previewRunning;
@property (nonatomic, assign) uint64_t     lastDisplayedSeq;
@end

@implementation VCAMControlViewController

- (void)dealloc {
    [self.previewTimer invalidate];
    [[VCAMStreamPreviewPump shared] detach];
    [self vcam_stopPreview];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.previewLayer && self.previewHostView)
        self.previewLayer.frame = self.previewHostView.bounds;
}

- (int)vcam_configPort {
    int p = [[VCAMLoadRawConfig()[@"port"] respondsToSelector:@selector(intValue)]
              ? VCAMLoadRawConfig()[@"port"] : @7878 intValue];
    return (p > 0 && p <= 65535) ? p : 7878;
}

- (void)vcam_resetPreviewLayer {
    self.lastDisplayedSeq = 0;
    if (!self.previewLayer) return;
    if ([self.previewLayer respondsToSelector:@selector(flushAndRemoveImage)])
        [self.previewLayer flushAndRemoveImage];
    else [self.previewLayer flush];
}

- (void)vcam_setPreviewHint:(NSDictionary *)status {
    BOOL connected = [status[@"connected"] boolValue];
    BOOL hasFrame  = [status[@"has_frame"]  boolValue];
    double ageMs   = [status[@"age_ms"] doubleValue];
    NSString *err  = [status[@"error"] isKindOfClass:[NSString class]] ? status[@"error"] : @"";

    BOOL fresh = hasFrame && ageMs >= 0.0 && ageMs < 1200.0;
    if (fresh) { self.previewHintLabel.hidden = YES; return; }

    self.previewHintLabel.hidden = NO;
    if (!self.previewRunning)   { self.previewHintLabel.text = @"\u9884\u89c8\u672a\u542f\u52a8"; return; }
    if (!connected)             { self.previewHintLabel.text = @"\u9884\u89c8\u8fde\u63a5\u4e2d..."; return; }
    if (!hasFrame && err.length){ self.previewHintLabel.text = [NSString stringWithFormat:@"\u91cd\u8fde\u4e2d: %@", err]; return; }
    self.previewHintLabel.text = @"\u5df2\u8fde\u63a5\uff0c\u6b63\u5728\u63a5\u6536\u5e27...";
}

- (void)vcam_updatePreviewTick {
    NSDictionary *status = [[VCAMSBPreviewReceiver shared] statusSnapshot];
    [self vcam_setPreviewHint:status];
    BOOL connected = [status[@"connected"] boolValue];
    BOOL hasFrame  = [status[@"has_frame"]  boolValue];
    double ageMs   = [status[@"age_ms"] doubleValue];
    if (connected && hasFrame && ageMs >= 0 && ageMs < 1500)
        self.statusLabel.textColor = [UIColor colorWithWhite:0.82 alpha:1];
    else if (self.previewRunning)
        self.statusLabel.textColor = [UIColor colorWithRed:0.95 green:0.72 blue:0.38 alpha:1];
    else
        self.statusLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1];
}

- (void)vcam_startPreviewWithHost:(NSString *)host port:(int)port {
    [self vcam_resetPreviewLayer];
    [[VCAMStreamPreviewPump shared] attachToPreviewLayer:self.previewLayer];
    self.previewRunning = YES;
    self.previewHintLabel.text = @"\u9884\u89c8\u8fde\u63a5\u4e2d...";
    self.previewHintLabel.hidden = NO;
    gVCAMLastSBManagerSyncAt = 0;
    [VCAMManager syncAndCheckStatus];
}

- (void)vcam_stopPreview {
    [[VCAMStreamPreviewPump shared] detach];
    self.previewRunning = NO;
    [self vcam_resetPreviewLayer];
    gVCAMLastSBManagerSyncAt = 0;
    [VCAMManager syncAndCheckStatus];
}

- (void)vcam_refreshStatus {
    NSDictionary *cfg = [VCAMManager loadStreamConfig];
    id enabledObj = [cfg[@"enabled"] respondsToSelector:@selector(boolValue)] ? cfg[@"enabled"] : @NO;
    BOOL enabled = [enabledObj boolValue];
    NSString *host = [cfg[@"host"] isKindOfClass:[NSString class]] ? cfg[@"host"] : @"127.0.0.1";
    int port = [[cfg[@"port"] respondsToSelector:@selector(intValue)] ? cfg[@"port"] : @7878 intValue];
    self.statusLabel.text = enabled
        ? [NSString stringWithFormat:@"\u72b6\u6001: \u5df2\u63a5\u7ba1 %@:%d", host, port]
        : @"\u72b6\u6001: \u672a\u63a5\u7ba1";
}

- (void)vcam_finishEditing { [self.view endEditing:YES]; }

- (UIToolbar *)vcam_keyboardToolbar {
    UIToolbar *tb = [[UIToolbar alloc] initWithFrame:CGRectMake(0,0,320,44)];
    tb.barStyle = UIBarStyleBlack; tb.translucent = YES;
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"\u5b8c\u6210" style:UIBarButtonItemStyleDone target:self action:@selector(vcam_finishEditing)];
    tb.items = @[flex, done];
    return tb;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    UIView *v = touch.view;
    while (v) { if ([v isKindOfClass:[UIControl class]] || [v isKindOfClass:[UITextField class]]) return NO; v = v.superview; }
    return YES;
}

- (void)onHostEditingDidEnd {
    NSString *h = self.hostField.text ?: @"";
    h = [[h stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
           stringByReplacingOccurrencesOfString:@"\u3002" withString:@"."];
    self.hostField.text = h;
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

- (void)onEnableTap {
    [self vcam_finishEditing];
    NSString *host = self.hostField.text ?: @"127.0.0.1";
    [VCAMManager saveStreamConfigEnabled:YES host:host port:[self vcam_configPort]];
    [self vcam_stopPreview];
    self.previewHintLabel.text = @"\u5df2\u5f00\u542f\u63a5\u7ba1\uff0c\u8bf7\u6253\u5f00\u7cfb\u7edf\u76f8\u673a\u67e5\u770b";
    self.previewHintLabel.hidden = NO;
    [self vcam_refreshStatus];
}

- (void)onDisableTap {
    [self vcam_finishEditing];
    NSDictionary *cfg = [VCAMManager loadStreamConfig];
    NSString *host = [cfg[@"host"] isKindOfClass:[NSString class]] ? cfg[@"host"] : @"127.0.0.1";
    int port = [[cfg[@"port"] respondsToSelector:@selector(intValue)] ? cfg[@"port"] : @7878 intValue];
    [VCAMManager saveStreamConfigEnabled:NO host:host port:port];
    self.previewHintLabel.text = @"\u63a5\u7ba1\u5df2\u5173\u95ed";
    self.previewHintLabel.hidden = NO;
    [self vcam_refreshStatus];
}

- (void)onSaveTap {
    [self vcam_finishEditing];
    NSString *host = self.hostField.text ?: @"127.0.0.1";
    int port = [self vcam_configPort];
    [VCAMManager saveStreamConfigEnabled:NO host:host port:port];
    [self vcam_stopPreview];
    [self vcam_startPreviewWithHost:host port:port];
    self.statusLabel.text = [NSString stringWithFormat:@"\u5df2\u4fdd\u5b58: %@:%d (\u9884\u89c8\u4e2d)", host, port];
}

- (void)onColorPickerTap:(UIButton *)sender {
    [[VCAMColorPickerSender shared] toggle];
    BOOL nowRunning = [VCAMColorPickerSender shared].running;
    NSString *title = nowRunning ? @"\u5173\u95ed\u95ea\u8272\u6293\u53d6 (Color Picker)"
                                 : @"\u5f00\u542f\u95ea\u8272\u6293\u53d6 (Color Picker)";
    [sender setTitle:title forState:UIControlStateNormal];
    sender.backgroundColor = nowRunning
        ? [UIColor colorWithRed:0.50 green:0.20 blue:0.12 alpha:1]
        : [UIColor colorWithRed:0.12 green:0.28 blue:0.50 alpha:1];
    VCAMAppendSBLog([NSString stringWithFormat:@"colorpicker toggled running=%d", nowRunning?1:0]);
}

- (void)onCancelTap {
    [self vcam_finishEditing];
    [self.previewTimer invalidate]; self.previewTimer = nil;
    [self vcam_stopPreview];
    // dismiss
    extern void VCAMDismissControlUI(void);
    VCAMDismissControlUI();
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    UIButton *mask = [UIButton buttonWithType:UIButtonTypeCustom];
    mask.frame = self.view.bounds;
    mask.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    mask.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.36];
    [mask addTarget:self action:@selector(onCancelTap) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:mask];

    CGRect bounds = self.view.bounds;
    CGFloat pw = MIN(CGRectGetWidth(bounds) - 28, 360), ph = 510;
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(
        (CGRectGetWidth(bounds) - pw) * 0.5, (CGRectGetHeight(bounds) - ph) * 0.5, pw, ph)];
    panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                             UIViewAutoresizingFlexibleTopMargin  | UIViewAutoresizingFlexibleBottomMargin;
    panel.backgroundColor   = [UIColor colorWithWhite:0.1 alpha:0.95];
    panel.layer.cornerRadius = 16;
    panel.layer.borderColor  = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
    panel.layer.borderWidth  = 1;
    [self.view addSubview:panel];
    self.panelView = panel;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(vcam_finishEditing)];
    tap.cancelsTouchesInView = NO; tap.delegate = self;
    [panel addGestureRecognizer:tap];

    // Title
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, pw - 32, 30)];
    title.text = @"\u5b9e\u65f6\u63a8\u6d41\u63a7\u5236\u53f0";
    title.textColor = [UIColor whiteColor]; title.font = [UIFont boldSystemFontOfSize:24];
    [panel addSubview:title];

    // Preview area
    UIView *preview = [[UIView alloc] initWithFrame:CGRectMake(16, 52, pw - 32, 150)];
    preview.backgroundColor = [UIColor blackColor];
    preview.layer.cornerRadius = 10; preview.layer.masksToBounds = YES;
    preview.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor; preview.layer.borderWidth = 1;
    [panel addSubview:preview];

    UIView *previewHost = [[UIView alloc] initWithFrame:preview.bounds];
    previewHost.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    previewHost.backgroundColor = [UIColor blackColor];
    [preview addSubview:previewHost]; self.previewHostView = previewHost;

    AVSampleBufferDisplayLayer *layer = [AVSampleBufferDisplayLayer layer];
    layer.frame = previewHost.bounds; layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    layer.opaque = YES; layer.backgroundColor = [UIColor blackColor].CGColor;
    [previewHost.layer addSublayer:layer]; self.previewLayer = layer;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, preview.bounds.size.width, preview.bounds.size.height)];
    hint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    hint.text = @"\u9884\u89c8\u672a\u8fde\u63a5"; hint.textAlignment = NSTextAlignmentCenter;
    hint.textColor = [UIColor colorWithWhite:0.75 alpha:1]; hint.font = [UIFont systemFontOfSize:14];
    [preview addSubview:hint]; self.previewHintLabel = hint;

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(16, 208, pw - 32, 16)];
    status.textColor = [UIColor colorWithWhite:0.72 alpha:1]; status.font = [UIFont systemFontOfSize:12];
    [panel addSubview:status]; self.statusLabel = status;

    NSDictionary *cfg = [VCAMManager loadStreamConfig];
    NSString *savedHost = [cfg[@"host"] isKindOfClass:[NSString class]] ? cfg[@"host"] : @"127.0.0.1";

    UITextField *hostField = [[UITextField alloc] initWithFrame:CGRectMake(16, 236, pw - 32, 46)];
    hostField.backgroundColor = [UIColor colorWithWhite:0.17 alpha:1];
    hostField.textColor = [UIColor whiteColor]; hostField.tintColor = [UIColor whiteColor];
    hostField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"\u8f93\u5165\u7535\u8111IP"
        attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.60 alpha:1]}];
    hostField.text = savedHost;
    hostField.clearButtonMode = UITextFieldViewModeWhileEditing;
    hostField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    hostField.keyboardAppearance = UIKeyboardAppearanceDark;
    hostField.returnKeyType = UIReturnKeyDone;
    hostField.autocorrectionType = UITextAutocorrectionTypeNo;
    hostField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    hostField.layer.cornerRadius = 10;
    hostField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 46)];
    hostField.leftViewMode = UITextFieldViewModeAlways;
    hostField.delegate = self;
    hostField.inputAccessoryView = [self vcam_keyboardToolbar];
    [hostField addTarget:self action:@selector(onHostEditingDidEnd) forControlEvents:UIControlEventEditingDidEnd];
    [panel addSubview:hostField]; self.hostField = hostField;

    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    saveBtn.frame = CGRectMake(16, 292, pw - 32, 38);
    saveBtn.backgroundColor = [UIColor colorWithRed:0.17 green:0.56 blue:0.31 alpha:1];
    [saveBtn setTitle:@"\u4fdd\u5b58\u5730\u5740\u5e76\u9884\u89c8" forState:UIControlStateNormal];
    [saveBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    saveBtn.layer.cornerRadius = 9;
    [saveBtn addTarget:self action:@selector(onSaveTap) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:saveBtn];

    UIButton *enableBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    enableBtn.frame = CGRectMake(16, 336, pw - 32, 44);
    enableBtn.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
    [enableBtn setTitle:@"\u5f00\u59cb\u63a5\u7ba1\u6444\u50cf\u5934" forState:UIControlStateNormal];
    [enableBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    enableBtn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    enableBtn.layer.cornerRadius = 10;
    [enableBtn addTarget:self action:@selector(onEnableTap) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:enableBtn];

    UIButton *disableBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    disableBtn.frame = CGRectMake(16, 386, pw - 32, 34);
    disableBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    [disableBtn setTitle:@"\u5173\u95ed\u63a5\u7ba1" forState:UIControlStateNormal];
    [disableBtn setTitleColor:[UIColor colorWithRed:1 green:0.45 blue:0.45 alpha:1] forState:UIControlStateNormal];
    disableBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    disableBtn.layer.cornerRadius = 9;
    [disableBtn addTarget:self action:@selector(onDisableTap) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:disableBtn];

    // ── 颜色抓取按钮 ──────────────────────────────────────────────────────────
    UIButton *colorPickerBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    colorPickerBtn.frame = CGRectMake(16, 426, pw - 32, 36);
    colorPickerBtn.backgroundColor = [UIColor colorWithRed:0.12 green:0.28 blue:0.50 alpha:1];
    BOOL cpRunning = [VCAMColorPickerSender shared].running;
    NSString *cpTitle = cpRunning ? @"\u5173\u95ed\u95ea\u8272\u6293\u53d6 (Color Picker)"
                                  : @"\u5f00\u542f\u95ea\u8272\u6293\u53d6 (Color Picker)";
    [colorPickerBtn setTitle:cpTitle forState:UIControlStateNormal];
    [colorPickerBtn setTitleColor:[UIColor colorWithRed:0.55 green:0.85 blue:1.0 alpha:1] forState:UIControlStateNormal];
    colorPickerBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    colorPickerBtn.layer.cornerRadius = 9;
    [colorPickerBtn addTarget:self action:@selector(onColorPickerTap:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:colorPickerBtn];

    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelBtn.frame = CGRectMake(16, 470, pw - 32, 26);
    [cancelBtn setTitle:@"\u53d6\u6d88\u64cd\u4f5c" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:[UIColor colorWithWhite:0.88 alpha:1] forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont systemFontOfSize:17];
    [cancelBtn addTarget:self action:@selector(onCancelTap) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:cancelBtn];

    self.previewTimer = [NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(vcam_updatePreviewTick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.previewTimer forMode:NSRunLoopCommonModes];
    self.previewRunning = NO;
    self.previewHintLabel.text = @"\u70b9\u51fb\u300c\u4fdd\u5b58\u5730\u5740\u5e76\u9884\u89c8\u300d\u540e\u5f00\u59cb";
    [self vcam_refreshStatus];
}

@end

// ─── Control window helpers ───────────────────────────────────────────────────
void VCAMDismissControlUI(void) {
    gIsPresentingControlUI = NO;
    if (gControlWindow) { gControlWindow.hidden = YES; gControlWindow = nil; }
}

static void VCAMPresentControlUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gProcessIsSpringBoard || gIsPresentingControlUI) return;
        gIsPresentingControlUI = YES;

        UIWindowScene *scene = VCAMFirstWindowScene();
        UIWindow *window = nil;
        if (scene && [UIWindow instancesRespondToSelector:@selector(initWithWindowScene:)])
            window = [[UIWindow alloc] initWithWindowScene:scene];
        else
            window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        window.windowLevel = UIWindowLevelAlert + 2;
        window.rootViewController = [VCAMControlViewController new];
        window.hidden = NO;
        [window makeKeyAndVisible];
        gControlWindow = window;
    });
}

// ─── Volume detection ─────────────────────────────────────────────────────────
static void VCAMHandleVolumeDirection(BOOL up) {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (up) gLastVolumeUpTime   = now;
    else    gLastVolumeDownTime = now;

    if (fabs(gLastVolumeUpTime - gLastVolumeDownTime) <= 0.55 && (now - gLastTriggerTime) > 1.0) {
        gLastTriggerTime = now;
        VCAMAppendSBLog(@"trigger by volume up/down combo");
        VCAMPresentControlUI();
    }
}

static BOOL VCAMReasonLooksLikeButton(NSString *reason) {
    if (!reason.length) return YES;
    NSString *lower = [reason lowercaseString];
    return [lower containsString:@"explicit"] || [lower containsString:@"button"] || [lower containsString:@"volume"];
}

static float VCAMReadOutputVolume(void) {
    Class cls = NSClassFromString(@"AVAudioSession");
    if (!cls) return -1;
    id session = ((id(*)(id,SEL))objc_msgSend)(cls, @selector(sharedInstance));
    if (!session) return -1;
    SEL activateSel = @selector(setActive:error:);
    if ([session respondsToSelector:activateSel]) {
        NSError *err = nil;
        ((BOOL(*)(id,SEL,BOOL,NSError**))objc_msgSend)(session, activateSel, YES, &err);
    }
    if (![session respondsToSelector:@selector(outputVolume)]) return -1;
    return ((float(*)(id,SEL))objc_msgSend)(session, @selector(outputVolume));
}

static void VCAMStartVolumePoller(void) {
    if (gVolumePollTimer) return;
    dispatch_queue_t q = dispatch_get_main_queue();
    gVolumePollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    if (!gVolumePollTimer) return;
    uint64_t interval = (uint64_t)(0.12 * NSEC_PER_SEC);
    dispatch_source_set_timer(gVolumePollTimer, dispatch_time(DISPATCH_TIME_NOW, interval), interval, (uint64_t)(0.02 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(gVolumePollTimer, ^{
        float volume = VCAMReadOutputVolume();
        if (volume < 0) return;
        if (gLastPolledVolume < 0) { gLastPolledVolume = volume; return; }
        float delta = volume - gLastPolledVolume;
        if (fabsf(delta) < 0.0001f) return;
        gLastPolledVolume = volume;
        VCAMHandleVolumeDirection(delta > 0);
    });
    dispatch_resume(gVolumePollTimer);
}

static void VCAMStartVolumeObserver(void) {
    if (gVolumeObserver) return;
    gVolumeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        NSDictionary *info = note.userInfo;
        NSNumber *value = [info[@"AVSystemController_AudioVolumeNotificationParameter"]
                           respondsToSelector:@selector(floatValue)]
            ? info[@"AVSystemController_AudioVolumeNotificationParameter"] : nil;
        if (!value) return;
        float volume = value.floatValue;
        if (gLastObservedVolume < 0) { gLastObservedVolume = volume; return; }
        float delta = volume - gLastObservedVolume;
        gLastObservedVolume = volume;
        if (fabsf(delta) < 0.0001f) return;
        NSString *reason = [info[@"AVSystemController_AudioVolumeChangeReasonNotificationParameter"]
                            isKindOfClass:[NSString class]]
            ? info[@"AVSystemController_AudioVolumeChangeReasonNotificationParameter"] : nil;
        if (VCAMReasonLooksLikeButton(reason))
            VCAMHandleVolumeDirection(delta > 0);
    }];
}

static void VCAMDarwinVolumeCB(CFNotificationCenterRef __unused c, void *__unused o,
                               CFStringRef __unused n, const void *__unused obj,
                               CFDictionaryRef __unused u) {}

static void VCAMStartDarwinVolumeObserver(void) {
    if (gDarwinVolumeObserverStarted) return;
    gDarwinVolumeObserverStarted = YES;
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL, VCAMDarwinVolumeCB,
        CFSTR("AVSystemController_SystemVolumeDidChangeNotification"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void VCAMStartShowUIObserver(void) {
    if (gShowUINotifyToken) return;
    notify_register_dispatch(kVCAMShowUINotify, &gShowUINotifyToken, dispatch_get_main_queue(), ^(int __unused t) {
        notify_post(kVCAMShowUIAckNotify);
        VCAMPresentControlUI();
    });
}

static int gColorPickerNotifyToken = 0;
static void VCAMStartColorPickerObserver(void) {
    if (gColorPickerNotifyToken) return;
    notify_register_dispatch(kVCAMColorPickerToggleNotify, &gColorPickerNotifyToken,
                             dispatch_get_main_queue(), ^(int __unused t) {
        [[VCAMColorPickerSender shared] toggle];
    });
}

static void VCAMHandlePhysicalButtonEvent(id event) {
    if (!gProcessIsSpringBoard || !event) return;
    BOOL up = VCAMEventLooksVolumeUp(event), down = VCAMEventLooksVolumeDown(event);
    if (up)   VCAMHandleVolumeDirection(YES);
    if (down)  VCAMHandleVolumeDirection(NO);
}

// ─── Hooks ────────────────────────────────────────────────────────────────────
%hook SpringBoard
- (void)_handlePhysicalButtonEvent:(id)e { %orig(e); VCAMHandlePhysicalButtonEvent(e); }
- (void)handlePhysicalButtonEvent:(id)e  { %orig(e); VCAMHandlePhysicalButtonEvent(e); }
%end

%hook SBMainWorkspace
- (void)_handlePhysicalButtonEvent:(id)e { %orig(e); VCAMHandlePhysicalButtonEvent(e); }
- (void)handlePhysicalButtonEvent:(id)e  { %orig(e); VCAMHandlePhysicalButtonEvent(e); }
%end

%hook SBUIController
- (void)_handlePhysicalButtonEvent:(id)e { %orig(e); VCAMHandlePhysicalButtonEvent(e); }
- (void)handlePhysicalButtonEvent:(id)e  { %orig(e); VCAMHandlePhysicalButtonEvent(e); }
%end

%hook AVCaptureSession
- (void)startRunning { %orig; [VCAMManager setCameraSessionRunning:YES]; }
- (void)stopRunning  { %orig; [VCAMManager setCameraSessionRunning:NO];  }
%end

%hook AVCaptureMovieFileOutput
- (void)startRecordingToOutputFileURL:(NSURL *)url recordingDelegate:(id)delegate {
    [VCAMManager syncAndCheckStatus]; %orig(url, delegate);
}
%end

// ─── Constructor ──────────────────────────────────────────────────────────────
%ctor {
    @autoreleasepool {
        NSString *proc = NSProcessInfo.processInfo.processName ?: @"unknown";
        if (![proc isEqualToString:@"SpringBoard"]) return;
        gProcessIsSpringBoard = YES;
        NSString *mark = [NSString stringWithFormat:@"loaded_at=%f\nprocess=%@\n", CFAbsoluteTimeGetCurrent(), proc];
        [mark writeToFile:kVCAMSpringBoardMarkerPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        VCAMAppendSBLog([NSString stringWithFormat:@"loaded in %@", proc]);
        VCAMStartVolumeObserver();
        VCAMStartVolumePoller();
        VCAMStartDarwinVolumeObserver();
        VCAMStartShowUIObserver();
        VCAMStartColorPickerObserver();
        [VCAMManager syncAndCheckStatus];
        NSLog(@"[VCAMCloneSB] loaded in SpringBoard");
        notify_post(kVCAMMediaNotify);
    }
}
