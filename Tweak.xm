#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>
#import <UIKit/UIKit.h>
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
static VTPixelTransferSessionRef gVCAMPixelTransferSession = NULL;
static NSObject      *gVCAMRenderedFrameLock  = nil;
static NSMutableArray *gVCAMRenderedFrameCache = nil;
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

// ─── JPEG → CVPixelBufferRef (32BGRA) ────────────────────────────────────────
static CVPixelBufferRef VCAMCreatePixelBufferFromJPEGData(NSData *jpegData) {
    UIImage *img = [UIImage imageWithData:jpegData];
    if (!img || img.size.width <= 0 || img.size.height <= 0) return NULL;

    size_t w = (size_t)img.size.width;
    size_t h = (size_t)img.size.height;

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey:             @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey:         @{},
        (id)kCVPixelBufferCGImageCompatibilityKey:        @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES,
    };

    CVPixelBufferRef buf = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &buf) != kCVReturnSuccess || !buf)
        return NULL;

    CVPixelBufferLockBaseAddress(buf, 0);
    CGColorSpaceRef cs  = CGColorSpaceCreateDeviceRGB();
    CGContextRef    ctx = CGBitmapContextCreate(
        CVPixelBufferGetBaseAddress(buf), w, h, 8,
        CVPixelBufferGetBytesPerRow(buf), cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img.CGImage);
        CGContextRelease(ctx);
    }
    CVPixelBufferUnlockBaseAddress(buf, 0);
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
@end

@interface VCAMService : NSObject
+ (instancetype)shared;
- (void)startObserver;
- (void)applyConfig;
- (void)syncAndCheckStatus;
- (void)ensureReceiverStartedIfNeeded;
- (CMSampleBufferRef)copyLatestSampleBuffer;
- (CVImageBufferRef)copyLatestImageBuffer;
@end

@interface VCAMManager : NSObject
+ (void)syncAndCheckStatus;
+ (CMSampleBufferRef)copyLatestSampleBuffer;
+ (CVImageBufferRef)copyLatestImageBuffer;
@end

// ─── Rendered frame cache (keeps +0 refs returned by the hook alive) ──────────
static NSObject *VCAMRenderedFrameLockObject(void) {
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{
        gVCAMRenderedFrameLock  = [NSObject new];
        gVCAMRenderedFrameCache = [NSMutableArray array];
    });
    return gVCAMRenderedFrameLock;
}

static void VCAMRememberRenderedFrame(CVPixelBufferRef buf) {
    if (!buf) return;
    NSObject *lock = VCAMRenderedFrameLockObject();
    @synchronized (lock) {
        [gVCAMRenderedFrameCache addObject:(__bridge id)buf];
        while (gVCAMRenderedFrameCache.count > 8)
            [gVCAMRenderedFrameCache removeObjectAtIndex:0];
    }
}

// ─── Shared VTPixelTransferSession (format + scale conversion) ───────────────
static VTPixelTransferSessionRef VCAMSharedPixelTransferSession(void) {
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{
        VTPixelTransferSessionRef s = NULL;
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &s) == noErr && s) {
            VTSessionSetProperty(s, kVTPixelTransferPropertyKey_RealTime,    kCFBooleanTrue);
            VTSessionSetProperty(s, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Normal);
            gVCAMPixelTransferSession = s;
        } else {
            VCAMAppendMediaLog(@"pixel transfer session create failed");
        }
    });
    return gVCAMPixelTransferSession;
}

// ─── Scale / convert fake frame to match original format exactly ──────────────
static CVPixelBufferRef VCAMCreateRenderedImageMatchingOriginal(
        CVPixelBufferRef sourceImage, CVPixelBufferRef originalImage) {

    if (!sourceImage || !originalImage) return NULL;

    size_t dstW  = CVPixelBufferGetWidth(originalImage);
    size_t dstH  = CVPixelBufferGetHeight(originalImage);
    OSType dstFmt = CVPixelBufferGetPixelFormatType(originalImage);
    if (!dstW || !dstH) return NULL;

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(dstFmt),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef target = NULL;
    CVReturn err = CVPixelBufferCreate(kCFAllocatorDefault, dstW, dstH, dstFmt,
                                       (__bridge CFDictionaryRef)attrs, &target);
    if (err != kCVReturnSuccess || !target) {
        VCAMAppendMediaLog([NSString stringWithFormat:
            @"target buf create failed err=%d fmt=%u %zux%zu", (int)err, dstFmt, dstW, dstH]);
        return NULL;
    }

    VTPixelTransferSessionRef session = VCAMSharedPixelTransferSession();
    if (!session) { CVPixelBufferRelease(target); return NULL; }

    OSStatus st = VTPixelTransferSessionTransferImage(session, sourceImage, target);
    if (st != noErr) {
        VCAMAppendMediaLog([NSString stringWithFormat:
            @"pixel transfer failed st=%d srcFmt=%u dstFmt=%u src=%zux%zu dst=%zux%zu",
            (int)st,
            (unsigned)CVPixelBufferGetPixelFormatType(sourceImage), (unsigned)dstFmt,
            CVPixelBufferGetWidth(sourceImage), CVPixelBufferGetHeight(sourceImage),
            dstW, dstH]);
        CVPixelBufferRelease(target); return NULL;
    }

    CFDictionaryRef att = CVBufferCopyAttachments(originalImage, kCVAttachmentMode_ShouldPropagate);
    if (att) { CVBufferSetAttachments(target, att, kCVAttachmentMode_ShouldPropagate); CFRelease(att); }

    VCAMRememberRenderedFrame(target);
    CVPixelBufferRelease(target); // cache holds +1, return +0 (same semantics as CMSampleBufferGetImageBuffer)
    return target;
}

// ─── The actual hook function ─────────────────────────────────────────────────
static CVImageBufferRef VCAMHookedCMSampleBufferGetImageBuffer(CMSampleBufferRef sampleBuffer) {
    if (!gOrigCMSampleBufferGetImageBuffer) return NULL;
    [VCAMManager syncAndCheckStatus];
    CVImageBufferRef originalImage = gOrigCMSampleBufferGetImageBuffer(sampleBuffer);
    CVImageBufferRef latestImage   = [VCAMManager copyLatestImageBuffer];
    gVCAMHookProbeCount++;
    if (latestImage && originalImage) {
        CVPixelBufferRef rendered = VCAMCreateRenderedImageMatchingOriginal(
            (CVPixelBufferRef)latestImage, (CVPixelBufferRef)originalImage);
        CFRelease(latestImage);
        if (rendered) {
            if ((gVCAMHookProbeCount % 180) == 0)
                VCAMAppendMediaLog([NSString stringWithFormat:
                    @"hook probe=%llu enabled=1 hasFrame=1", (unsigned long long)gVCAMHookProbeCount]);
            return rendered;
        }
    } else if (latestImage) {
        CFRelease(latestImage);
    }
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
    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, imageBuffer, &fmt) != noErr || !fmt)
        return;

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

@end

// ─── VCAMManager ──────────────────────────────────────────────────────────────
@implementation VCAMManager
+ (void)syncAndCheckStatus     { [[VCAMService shared] syncAndCheckStatus]; }
+ (CMSampleBufferRef)copyLatestSampleBuffer { return [[VCAMService shared] copyLatestSampleBuffer]; }
+ (CVImageBufferRef)copyLatestImageBuffer   { return [[VCAMService shared] copyLatestImageBuffer]; }
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
