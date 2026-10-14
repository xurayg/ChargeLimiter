#include "ui.h"
#include "utils.h"

static int g_jbtype     = -1;
static int g_wind_type  = 0; // 1: HUD

static void daemonRun(NSArray* nsreq);

@implementation HUDMainWindow
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    return self;
}
- (BOOL)_isWindowServerHostingManaged {
    return NO;
}
@end

@implementation AppDelegate
static UIView* _mainWnd = nil;
static AppDelegate* _app = nil;
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)connectionOptions API_AVAILABLE(ios(13.0)) {
    if (connectionOptions.URLContexts != nil) {
        [self scene:scene openURLContexts:connectionOptions.URLContexts];
    }
}
- (void)scene:(UIScene*)scene openURLContexts:(NSSet*)URLContexts API_AVAILABLE(ios(13.0)) {
    if (URLContexts == nil || URLContexts.count == 0) {
        return;
    }
    UIOpenURLContext* urlContext = URLContexts.allObjects.firstObject;
    NSURL* url = urlContext.URL; // cl:///(charge|nocharge)(/exit)
    for (NSString* cmd in url.pathComponents) {
        if ([cmd isEqualToString:@"charge"]) {
            daemonRun(@[@"set_charge", @"1"]);
        } else if ([cmd isEqualToString:@"nocharge"]) {
            daemonRun(@[@"set_charge", @"0"]);
        } else if ([cmd hasPrefix:@"exit"]) {
            int n = 1;
            if (cmd.length > 4) {
                NSString* nn = [cmd substringFromIndex:4];
                n = [nn intValue];
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, n * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{
                exit(0);
            });
        }
    }
}
- (void)sceneWillEnterForeground:(UIScene*)scene API_AVAILABLE(ios(13.0)) {
    _mainWnd = self.window;
}
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey,id>*)launchOptions {
    if (g_wind_type == 0) {
        _mainWnd = self.window;
    } else if (g_wind_type == 1) { // from TrollSpeed
        self.window = [[HUDMainWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        self.window.rootViewController = [AppDelegate new];
        self.window.windowLevel = 10000010.0;
        self.window.hidden = NO;
        [self.window makeKeyAndVisible];
        static SBSAccessibilityWindowHostingController* _accessController = [objc_getClass("SBSAccessibilityWindowHostingController") new];
        if (_accessController != nil) {
            unsigned int _contextId = [self.window _contextId];
            double windowLevel = [self.window windowLevel];
            [_accessController registerWindowWithContextID:_contextId atLevel:windowLevel];
        }
    }
    return YES;
}
- (void)viewDidAppear:(BOOL)animated {
    @autoreleasepool {
        [super viewDidAppear:animated];
        static CGSize scrSize = UIScreen.mainScreen.bounds.size;
        _app = self;
        if (g_wind_type == 0) {
            if (!self.childViewControllers.count) {
                UIViewController* native = CLCreateNativeInterface();
                [self addChildViewController:native];
                native.view.frame = self.view.bounds;
                native.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [self.view addSubview:native.view];
                [native didMoveToParentViewController:self];
            }
        } else if (g_wind_type == 1) {
            if (self.hudView) return;
            _mainWnd = self.view;
            self.view.backgroundColor = UIColor.clearColor;
            self.hudView = [[CLNativeHUD alloc] initWithFrame:CGRectMake(FLOAT_ORIGINX, FLOAT_ORIGINY, FLOAT_WIDTH, FLOAT_HEIGHT)];
            [self.view addSubview:self.hudView];
            [self.hudView startUpdating];
            BKSHIDEventRegisterEventCallback([](void* target, void* refcon, IOHIDServiceRef service, IOHIDEventRef event) {
                @autoreleasepool {
                    IOHIDEventType type = IOHIDEventGetType(event);
                    if (type != kIOHIDEventTypeDigitizer) {
                        return;
                    }
                    CFArrayRef ref = IOHIDEventGetChildren(event);
                    if (!ref || CFArrayGetCount(ref) == 0) {
                        return;
                    }
                    IOHIDEventRef event2 = (IOHIDEventRef)CFArrayGetValueAtIndex(ref, 0);
                    int x = IOHIDEventGetIntegerValue(event2, kIOHIDEventFieldDigitizerX);
                    int y = IOHIDEventGetIntegerValue(event2, kIOHIDEventFieldDigitizerY);
                    int mask = IOHIDEventGetIntegerValue(event2, kIOHIDEventFieldDigitizerEventMask);
                    if ((mask & kIOHIDDigitizerEventPosition) != 0) { // touch_move
                        dispatch_async(dispatch_get_main_queue(), ^{
                            int f_x = MAX(x - FLOAT_WIDTH/2, 0);
                            int f_y = MAX(y - FLOAT_HEIGHT/2, 50); // 防止刘海屏上拉残缺
                            f_x = MIN(f_x, scrSize.width - FLOAT_WIDTH);
                            f_y = MIN(f_y, scrSize.height - FLOAT_HEIGHT);
                            CGRect rt = _app.hudView.frame;
                            [_app.hudView setFrame:CGRectMake(f_x, f_y, rt.size.width, rt.size.height)];
                        });
                    } else {
                        [UIApplication.sharedApplication _enqueueHIDEvent:event];
                    }
                }
            });
            
            static UIDeviceOrientation cur_orient = UIDevice.currentDevice.orientation;
            static FBSOrientationObserver* orientObserver = [objc_getClass("FBSOrientationObserver") new];
            [orientObserver setHandler:^(FBSOrientationUpdate* update) {
                if (update.orientation == cur_orient) {
                    return;
                }
                cur_orient = update.orientation;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [_app.hudView setTransform:CGAffineTransformMakeRotation(getOrientAngle(update.orientation))];
                });
            }];
            
            static CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
            CFNotificationCenterAddObserver(center, (__bridge const void *)self, [](CFNotificationCenterRef center, void* observer, CFStringRef name, void const* object, CFDictionaryRef userInfo) {
                @autoreleasepool {
#define     FRONTMOST_DELAY   20
                    static int last_access_time = 0;
                    static bool in_process = false;
                    int ts = (int)time(0);
                    last_access_time = ts;
                    if (in_process) {
                        return;
                    }
                    NSString* self_bid = NSBundle.mainBundle.bundleIdentifier;
                    NSArray* white_list = @[@"", self_bid]; // 作为前台桌面的进程
                    static NSString* old_bid = self_bid; // 悬浮窗从CL诞生
                    dispatch_async(dispatch_get_global_queue(0, 0), ^{
                        @autoreleasepool {
                            in_process = true;
                            for (int i = ts; i < last_access_time + FRONTMOST_DELAY; i++) { // 每次通知增加上限时间,等待bid变化
                                NSArray* cur_bid_list = getFrontMostBid();
                                NSString* cur_bid = @"";
                                if (cur_bid_list.count > 0) {
                                    if ([cur_bid_list containsObject:self_bid]) {
                                        cur_bid = self_bid;
                                    } else {
                                        cur_bid = cur_bid_list.firstObject;
                                    }
                                }
                                if (![old_bid isEqualToString:cur_bid]) {
                                    NSNumber* floatwnd_auto = getlocalKV(@"floatwnd_auto");
                                    if (floatwnd_auto.boolValue) {
                                        if ([white_list containsObject:cur_bid]) {
                                            NSFileLog(@"floatwnd unhide for %@", cur_bid);
                                            dispatch_async(dispatch_get_main_queue(), ^{
                                                _app.hudView.hidden = NO;
                                            });
                                        } else {
                                            NSFileLog(@"floatwnd hide for %@", cur_bid);
                                            dispatch_async(dispatch_get_main_queue(), ^{
                                                _app.hudView.hidden = YES;
                                            });
                                        }
                                    }
                                    old_bid = cur_bid;
                                    break; // 已变化,满足条件退出
                                }
                                old_bid = cur_bid;
                                [NSThread sleepForTimeInterval:1.0];
                            }
                            in_process = false;
                        }
                    });
                }
            }, CFSTR("com.apple.mobile.SubstantialTransition"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }
    }
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

@end

static void* make_sym_readable(void *ptr) {
#if __arm64e__
    if (!ptr) return ptr;
    ptr = ptrauth_strip(ptr, ptrauth_key_function_pointer);
#endif
    return ptr;
}

static void* make_sym_callable(void *ptr) {
#if __arm64e__
    if (!ptr) return ptr;
    ptr = ptrauth_sign_unauthenticated(ptrauth_strip(ptr, ptrauth_key_function_pointer), ptrauth_key_function_pointer, 0);
#endif
    return ptr;
}

@implementation HUDMainApplication
- (instancetype)init {
    self = [super init];
    do {
        UIEventDispatcher* dispatcher = (UIEventDispatcher*)[self valueForKey:@"eventDispatcher"];
        if (!dispatcher) {
            break;
        }
        if ([dispatcher respondsToSelector:@selector(_installEventRunLoopSources:)]) { // -[UIApplication _run]
            CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
            [dispatcher _installEventRunLoopSources:mainRunLoop];
        } else { // iOS>=16?
            IMP runMethodIMP = class_getMethodImplementation([self class], @selector(_run));
            if (!runMethodIMP) {
                break;
            }
            uint32_t* runMethodPtr = (uint32_t*)make_sym_readable((void *)runMethodIMP);
            void (*orig_UIEventDispatcher__installEventRunLoopSources_)(id, SEL, CFRunLoopRef) = NULL;
            for (int i = 0; i < 0x140; i++) {
                // mov x2, x0
                // mov x0, x?
                if (runMethodPtr[i] != 0xaa0003e2 || (runMethodPtr[i + 1] & 0xff000000) != 0xaa000000) {
                    continue;
                }
                // bl -[UIEventDispatcher _installEventRunLoopSources:]
                uint32_t blInst = runMethodPtr[i + 2];
                uint32_t* blInstPtr = &runMethodPtr[i + 2];
                if ((blInst & 0xfc000000) != 0x94000000) {
                    continue;
                }
                int32_t blOffset = blInst & 0x03ffffff;
                if (blOffset & 0x02000000)
                    blOffset |= 0xfc000000;
                blOffset <<= 2;
                uint64_t blAddr = (uint64_t)blInstPtr + blOffset;
                // cbz x0, loc_?????????
                uint32_t cbzInst = *((uint32_t*)make_sym_readable((void*)blAddr));
                if ((cbzInst & 0xff000000) != 0xb4000000) {
                    continue;
                }
                orig_UIEventDispatcher__installEventRunLoopSources_ = (void (*)(id __strong, SEL, CFRunLoopRef))make_sym_callable((void*)blAddr);
            }
            if (!orig_UIEventDispatcher__installEventRunLoopSources_) {
                break;
            }
            CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
            orig_UIEventDispatcher__installEventRunLoopSources_(dispatcher, @selector(_installEventRunLoopSources:), mainRunLoop);
        }
        UIEventFetcher *fetcher = [objc_getClass("UIEventFetcher") new];
        [dispatcher setValue:fetcher forKey:@"eventFetcher"];
        if ([fetcher respondsToSelector:@selector(setEventFetcherSink:)]) {
            [fetcher setEventFetcherSink:dispatcher];
        } else { // iOS>=16?
            [fetcher setValue:dispatcher forKey:@"eventFetcherSink"];
        }
        [self setValue:fetcher forKey:@"eventFetcher"];
    } while (NO);
    
    return self;
}
@end


void daemonRun(NSArray* argv) {
    NSString* bundlePath = [getSelfExePath() stringByDeletingLastPathComponent];
    NSString* daemonPath = [bundlePath stringByAppendingPathComponent:@"ChargeLimiterDaemon"];
    NSMutableArray* mArgv = [NSMutableArray array];
    [mArgv addObject:daemonPath];
    if (argv != nil) {
        [mArgv addObjectsFromArray:argv];
    }
    spawn(mArgv, nil, nil, 0, SPAWN_FLAG_ROOT | SPAWN_FLAG_NOWAIT);
}

static void start_daemon() {
    @autoreleasepool {
        if (g_jbtype == JBTYPE_TROLLSTORE) {
            // The independent watchdog owns retries and handles an unresponsive
            // HTTP server too. Re-launching it is safe: its process lease is unique.
            NSTimer* start_daemon_timer = [NSTimer timerWithTimeInterval:60 repeats:YES block:^(NSTimer* timer) {
                @autoreleasepool {
                    NSString* path = [[getSelfExePath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"ChargeLimiterWatchdog"];
                    spawn(@[path], nil, nil, nil, SPAWN_FLAG_ROOT | SPAWN_FLAG_NOWAIT);
                }
            }];
            [start_daemon_timer fire];
            [NSRunLoop.currentRunLoop addTimer:start_daemon_timer forMode:NSRunLoopCommonModes];
        }
    }
}

int main(int argc, char** argv) { // ChargeLimiter
    @autoreleasepool {
        g_jbtype = getJBType();
        if (argc == 1) {
            start_daemon();
            return UIApplicationMain(argc, argv, nil, @"AppDelegate");
        } else if (argc > 1) {
            if (0 == strcmp(argv[1], "floatwnd")) {
                start_daemon();
                g_wind_type = 1;
                static id<UIApplicationDelegate> appDelegate = [AppDelegate new];
                UIApplicationInstantiateSingleton(HUDMainApplication.class);
                static UIApplication* app = [UIApplication sharedApplication];
                [app setDelegate:appDelegate];
                [app __completeAndRunAsPlugin];
                CFRunLoopRun();
                return 0;
            }
        }
        return -1;
    }
}

