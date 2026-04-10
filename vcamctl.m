#import <Foundation/Foundation.h>
#import <notify.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <unistd.h>
#import <string.h>

static NSString *const kVCAMConfigPath = @"/var/tmp/vcam_stream.conf";
static NSString *const kVCAMSpringBoardMarkerPath = @"/var/tmp/vcam_springboard_loaded.txt";
static NSString *const kVCAMProcessLogPath = @"/var/tmp/vcam_proc.log";
static NSString *const kVCAMMediaLogPath = @"/var/tmp/vcam_media.log";
static NSString *const kVCAMSBEventLogPath = @"/var/tmp/vcam_sb_events.log";
static const char *kVCAMConfigNotify = "com.vcam.stream.config";
static const char *kVCAMMediaNotify = "com.vcam.media.stream.recv";
static const char *kVCAMShowUINotify = "com.vcam.showui";
static const char *kVCAMShowUIAckNotify = "com.vcam.showui.ack";

static NSDictionary *DefaultConfig(void) {
    return @{ @"enabled": @NO, @"host": @"127.0.0.1", @"port": @7878 };
}

static NSDictionary *LoadConfig(void) {
    NSData *data = [NSData dataWithContentsOfFile:kVCAMConfigPath];
    if (!data) {
        return DefaultConfig();
    }

    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        return (NSDictionary *)obj;
    }

    NSDictionary *plistObj = [NSDictionary dictionaryWithContentsOfFile:kVCAMConfigPath];
    if ([plistObj isKindOfClass:[NSDictionary class]]) {
        return plistObj;
    }

    return DefaultConfig();
}

static BOOL SaveConfig(NSDictionary *config, NSString **errorText) {
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:&jsonError];
    if (!jsonData) {
        if (errorText) {
            *errorText = [NSString stringWithFormat:@"json encode failed: %@", jsonError];
        }
        return NO;
    }

    BOOL ok = [jsonData writeToFile:kVCAMConfigPath options:NSDataWritingAtomic error:&jsonError];
    if (!ok) {
        if (errorText) {
            *errorText = [NSString stringWithFormat:@"write failed: %@", jsonError];
        }
        return NO;
    }

    notify_post(kVCAMConfigNotify);
    notify_post(kVCAMMediaNotify);
    return YES;
}

static void PrintUsage(void) {
    printf("vcamctl usage:\n");
    printf("  vcamctl status\n");
    printf("  vcamctl enable <host> [port]\n");
    printf("  vcamctl set <host> [port]     (same as enable)\n");
    printf("  vcamctl disable\n");
    printf("  vcamctl probe <host> [port]   (test TCP connect from phone to PC)\n");
    printf("  vcamctl trace                 (print tweak logs)\n");
    printf("  vcamctl popup                 (ask SpringBoard to show control UI)\n");
    printf("  vcamctl popupwait             (popup + wait SpringBoard ack)\n");
    printf("  vcamctl diag                  (check if SpringBoard hook loaded)\n");
}

static int ProbeTCPHost(NSString *host, int port, int timeoutSec) {
    if (host.length == 0 || port <= 0 || port > 65535) {
        return EINVAL;
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return errno;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host.UTF8String, &addr.sin_addr) != 1) {
        close(fd);
        return EINVAL;
    }

    int r = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (r == 0) {
        close(fd);
        return 0;
    }
    if (errno != EINPROGRESS) {
        int e = errno;
        close(fd);
        return e;
    }

    fd_set wfds;
    FD_ZERO(&wfds);
    FD_SET(fd, &wfds);
    struct timeval tv;
    tv.tv_sec = timeoutSec > 0 ? timeoutSec : 2;
    tv.tv_usec = 0;

    int sel = select(fd + 1, NULL, &wfds, NULL, &tv);
    if (sel <= 0) {
        close(fd);
        return sel == 0 ? ETIMEDOUT : errno;
    }

    int soError = 0;
    socklen_t soLen = sizeof(soError);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen) != 0) {
        int e = errno;
        close(fd);
        return e;
    }

    close(fd);
    return soError;
}

static void PrintLogFile(NSString *path, const char *title) {
    printf("---- %s (%s) ----\n", title, path.UTF8String);
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) {
        printf("(empty or missing)\n");
        return;
    }
    NSString *txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (txt.length == 0) {
        printf("(non-utf8 log)\n");
        return;
    }
    printf("%s\n", txt.UTF8String);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            PrintUsage();
            return 1;
        }

        NSString *cmd = [NSString stringWithUTF8String:argv[1]];

        if ([cmd isEqualToString:@"status"]) {
            NSDictionary *cfg = LoadConfig();
            BOOL enabled = [cfg[@"enabled"] boolValue];
            NSString *host = [cfg[@"host"] isKindOfClass:[NSString class]] ? cfg[@"host"] : @"127.0.0.1";
            int port = [cfg[@"port"] intValue];
            if (port <= 0 || port > 65535) {
                port = 7878;
            }

            printf("enabled: %s\n", enabled ? "true" : "false");
            printf("host: %s\n", host.UTF8String);
            printf("port: %d\n", port);
            printf("config: %s\n", kVCAMConfigPath.UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"disable"]) {
            NSDictionary *cfg = @{ @"enabled": @NO, @"host": @"127.0.0.1", @"port": @7878 };
            NSString *err = nil;
            if (!SaveConfig(cfg, &err)) {
                fprintf(stderr, "[vcamctl] %s\n", err.UTF8String);
                return 2;
            }
            printf("[vcamctl] disabled\n");
            return 0;
        }

        if ([cmd isEqualToString:@"probe"]) {
            if (argc < 3) {
                PrintUsage();
                return 1;
            }
            NSString *host = [NSString stringWithUTF8String:argv[2]];
            int port = 7878;
            if (argc >= 4) {
                port = [[NSString stringWithUTF8String:argv[3]] intValue];
            }
            int e = ProbeTCPHost(host, port, 2);
            if (e == 0) {
                printf("[vcamctl] probe success host=%s port=%d\n", host.UTF8String, port);
                return 0;
            }
            printf("[vcamctl] probe failed host=%s port=%d errno=%d\n", host.UTF8String, port, e);
            return 4;
        }

        if ([cmd isEqualToString:@"trace"]) {
            PrintLogFile(kVCAMSBEventLogPath, "springboard");
            PrintLogFile(kVCAMProcessLogPath, "process");
            PrintLogFile(kVCAMMediaLogPath, "media");
            return 0;
        }

        if ([cmd isEqualToString:@"popup"]) {
            notify_post(kVCAMShowUINotify);
            printf("[vcamctl] popup notify posted\n");
            return 0;
        }

        if ([cmd isEqualToString:@"popupwait"]) {
            __block BOOL ack = NO;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            dispatch_queue_t q = dispatch_queue_create("com.vcam.popupwait", DISPATCH_QUEUE_SERIAL);
            int token = 0;
            notify_register_dispatch(kVCAMShowUIAckNotify, &token, q, ^(__unused int t) {
                ack = YES;
                dispatch_semaphore_signal(sem);
            });

            notify_post(kVCAMShowUINotify);
            long waitRes = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
            if (token != 0) {
                notify_cancel(token);
            }

            if (waitRes == 0 && ack) {
                printf("[vcamctl] popup ack received from SpringBoard\n");
                return 0;
            }

            printf("[vcamctl] popup ack timeout (SpringBoard not responding)\n");
            return 3;
        }

        if ([cmd isEqualToString:@"diag"]) {
            BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:kVCAMSpringBoardMarkerPath];
            printf("springboard_marker_exists: %s\n", exists ? "true" : "false");
            if (exists) {
                NSData *data = [NSData dataWithContentsOfFile:kVCAMSpringBoardMarkerPath];
                if (data.length > 0) {
                    NSString *txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    if (txt.length > 0) {
                        printf("%s\n", txt.UTF8String);
                    }
                }
            }
            return 0;
        }

        if ([cmd isEqualToString:@"enable"] || [cmd isEqualToString:@"set"]) {
            if (argc < 3) {
                PrintUsage();
                return 1;
            }

            NSString *host = [NSString stringWithUTF8String:argv[2]];
            int port = 7878;
            if (argc >= 4) {
                port = [[NSString stringWithUTF8String:argv[3]] intValue];
            }

            if (host.length == 0) {
                fprintf(stderr, "[vcamctl] host is empty\n");
                return 1;
            }
            if (port <= 0 || port > 65535) {
                fprintf(stderr, "[vcamctl] invalid port: %d\n", port);
                return 1;
            }

            NSDictionary *cfg = @{ @"enabled": @YES, @"host": host, @"port": @(port) };
            NSString *err = nil;
            if (!SaveConfig(cfg, &err)) {
                fprintf(stderr, "[vcamctl] %s\n", err.UTF8String);
                return 2;
            }

            printf("[vcamctl] enabled host=%s port=%d\n", host.UTF8String, port);
            return 0;
        }

        PrintUsage();
        return 1;
    }
}
