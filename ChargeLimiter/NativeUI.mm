#include "NativeUI.h"
#include "common.h"
#include <cmath>

static NSString* CLText(NSString* chinese, NSString* english) {
    return [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"] ? chinese : english;
}
static UIColor* CLBackground() {
    if (@available(iOS 13.0, *)) return UIColor.systemGroupedBackgroundColor;
    return [UIColor colorWithWhite:0.95 alpha:1];
}
static UIColor* CLForeground() {
    if (@available(iOS 13.0, *)) return UIColor.labelColor;
    return UIColor.blackColor;
}
static NSString* CLPretty(id object) {
    if (!object) return @"";
    NSData* data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: [object description];
}

typedef void (^CLReply)(NSDictionary*, NSError*);
static void CLRequest(NSDictionary* body, CLReply completion) {
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/", GSERV_PORT]]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = [body[@"api"] isEqualToString:@"export_diagnostics"] ? 120 : ([body[@"api"] isEqualToString:@"get_service_status"] ? 3 : 5);
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        NSDictionary* result = nil;
        if (!error && data) {
            id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            if ([decoded isKindOfClass:NSDictionary.class]) result = decoded;
        }
        if (!error && (!result || [result[@"status"] intValue] != 0)) {
            error = [NSError errorWithDomain:@"ChargeLimiter.API" code:result ? [result[@"status"] integerValue] : -1 userInfo:@{NSLocalizedDescriptionKey:result[@"error"] ?: CLText(@"后台服务暂不可用，请稍后刷新。", @"The background service is unavailable. Please refresh shortly.")}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(result, error); });
    }] resume];
}

static NSString* const CLServiceConnectionChanged = @"CLServiceConnectionChanged";
static void CLConnectionLog(NSString* message) {
    NSDateFormatter* date = [NSDateFormatter new];
    date.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    CLAppendLog([NSString stringWithFormat:@"%@ app: %@\n", [date stringFromDate:NSDate.date], message], nil);
}
@interface CLServiceMonitor : NSObject
@property(nonatomic) BOOL connected;
@property(nonatomic) BOOL checked;
@property(nonatomic) BOOL checking;
@property(nonatomic, copy) NSDictionary* state;
@property(nonatomic, strong) NSTimer* timer;
@property(nonatomic, copy) NSString* lastInstance;
+ (instancetype)shared;
- (void)start;
- (NSString*)title;
@end
@implementation CLServiceMonitor
+ (instancetype)shared {
    static CLServiceMonitor* monitor;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ monitor = [CLServiceMonitor new]; });
    return monitor;
}
- (instancetype)init {
    if ((self = [super init])) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(start) name:UIApplicationDidBecomeActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stop) name:UIApplicationWillResignActiveNotification object:nil];
    }
    return self;
}
- (void)start {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (!self.timer) {
        self.checked = NO;
        [NSNotificationCenter.defaultCenter postNotificationName:CLServiceConnectionChanged object:self];
        __weak CLServiceMonitor* weakSelf = self;
        self.timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer* timer) { [weakSelf check]; }];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
    [self check];
}
- (void)stop { [self.timer invalidate]; self.timer = nil; }
- (NSString*)title {
    if (!self.checked) return CLText(@"正在检查后台服务…", @"Checking background service…");
    return self.connected ? CLText(@"● 后台服务已连接", @"● Service connected") : CLText(@"○ 后台服务无法连接或无响应", @"○ Service unavailable or unresponsive");
}
- (void)check {
    if (self.checking || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    self.checking = YES;
    CLRequest(@{@"api":@"get_service_status"}, ^(NSDictionary* response, NSError* error) {
        self.checking = NO;
        NSDictionary* state = [response[@"data"] isKindOfClass:NSDictionary.class] ? response[@"data"] : nil;
        BOOL connected = !error && [state[@"status"] isEqualToString:@"running"];
        NSString* instance = state[@"instance"];
        BOOL restarted = connected && self.lastInstance && instance && ![self.lastInstance isEqualToString:instance];
        BOOL changed = !self.checked || self.connected != connected || restarted;
        if (changed) {
            CLConnectionLog(connected ? [NSString stringWithFormat:@"service connected pid=%@ instance=%@", state[@"pid"], instance] : [NSString stringWithFormat:@"service connection lost/unavailable: %@ (may be stopped or unresponsive)", error.localizedDescription ?: @"invalid service status"]);
            if (restarted) CLConnectionLog([NSString stringWithFormat:@"service instance changed %@ -> %@ (restart detected)", self.lastInstance, instance]);
        }
        self.connected = connected;
        self.checked = YES;
        if (connected) { self.state = state; self.lastInstance = instance; }
        if (changed) [NSNotificationCenter.defaultCenter postNotificationName:CLServiceConnectionChanged object:self];
    });
}
@end

static void CLAlert(UIViewController* controller, NSString* title, NSString* message) {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:CLText(@"好", @"OK") style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}
static void CLShare(UIViewController* controller, NSArray<NSURL*>* files, UIBarButtonItem* anchor) {
    UIActivityViewController* activity = [[UIActivityViewController alloc] initWithActivityItems:files applicationActivities:nil];
    if (activity.popoverPresentationController) {
        if (anchor) activity.popoverPresentationController.barButtonItem = anchor;
        else {
            activity.popoverPresentationController.sourceView = controller.view;
            activity.popoverPresentationController.sourceRect = CGRectMake(controller.view.bounds.size.width / 2, controller.view.bounds.size.height / 2, 1, 1);
        }
    }
    [controller presentViewController:activity animated:YES completion:nil];
}

// Share copies live in a unique temporary directory; the authoritative export stays on the device.
static void CLDownloadExport(UIViewController* controller, NSDictionary* exportInfo, void (^finished)(void)) {
    NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSError* mkdirError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&mkdirError]) {
        CLAlert(controller, CLText(@"导出失败", @"Export failed"), mkdirError.localizedDescription);
        if (finished) finished();
        return;
    }
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray* files = [NSMutableArray new];
    __block NSError* firstError = nil;
    for (NSString* name in exportInfo[@"files"]) {
        dispatch_group_enter(group);
        NSString* saved = [exportInfo[@"directory"] stringByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager isReadableFileAtPath:saved]) {
            // Keep the permanent export intact and share a copy, also when the service is offline.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSError* error = nil;
                NSURL* destination = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:name]];
                [NSFileManager.defaultManager copyItemAtPath:saved toPath:destination.path error:&error];
                @synchronized (files) {
                    if (error && !firstError) firstError = error;
                    if (!error) [files addObject:destination];
                }
                dispatch_group_leave(group);
            });
            continue;
        }
        NSString* urlString = [NSString stringWithFormat:@"http://127.0.0.1:%d%@%@", GSERV_PORT, exportInfo[@"download_prefix"], name];
        NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        request.timeoutInterval = 120;
        [[NSURLSession.sharedSession downloadTaskWithRequest:request completionHandler:^(NSURL* tempURL, NSURLResponse* response, NSError* error) {
            NSURL* destination = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:name]];
            if (!error && [(NSHTTPURLResponse*)response statusCode] != 200) error = [NSError errorWithDomain:@"ChargeLimiter.Export" code:1 userInfo:@{NSLocalizedDescriptionKey:CLText(@"导出文件下载失败。", @"Could not download the export.")}];
            if (!error && tempURL) [NSFileManager.defaultManager moveItemAtURL:tempURL toURL:destination error:&error];
            @synchronized (files) {
                if (error && !firstError) firstError = error;
                if (!error) [files addObject:destination];
            }
            dispatch_group_leave(group);
        }] resume];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (finished) finished();
        if (!controller.view.window) return;
        if (firstError || !files.count) CLAlert(controller, CLText(@"导出失败", @"Export failed"), firstError.localizedDescription ?: @"No files");
        else CLShare(controller, files, controller.navigationItem.rightBarButtonItem);
    });
}

@interface CLTextController : UIViewController
@property(copy) NSString* content;
@property(copy) NSString* api;
@property(strong) UITextView* textView;
@end
@implementation CLTextController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = CLBackground();
    self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.editable = NO;
    self.textView.alwaysBounceVertical = YES;
    self.textView.font = [UIFont fontWithName:@"Menlo" size:13] ?: [UIFont systemFontOfSize:14];
    self.textView.textColor = CLForeground();
    self.textView.backgroundColor = CLBackground();
    self.textView.textContainerInset = UIEdgeInsetsMake(16, 16, 24, 16);
    self.textView.text = self.content;
    [self.view addSubview:self.textView];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(connectionChanged) name:CLServiceConnectionChanged object:nil];
    [self connectionChanged];
    if (self.api) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)];
        [self refresh];
    }
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)connectionChanged { self.navigationItem.prompt = CLServiceMonitor.shared.title; }
- (void)refresh {
    CLRequest(@{@"api":self.api}, ^(NSDictionary* response, NSError* error) {
        if (error && ([@[@"get_log", @"get_saved_conf"] containsObject:self.api])) {
            NSError* localError = nil;
            id local = [self.api isEqualToString:@"get_log"] ? CLReadLogTail(256 * 1024, &localError) : CLReadConfiguration(&localError);
            if (local) {
                self.navigationItem.prompt = CLText(@"服务未连接，显示设备已保存的数据", @"Service offline; showing saved device data");
                self.textView.text = [local isKindOfClass:NSString.class] ? local : CLPretty(local);
            } else CLAlert(self, CLText(@"读取失败", @"Read failed"), localError.localizedDescription ?: error.localizedDescription);
        } else if (error) CLAlert(self, CLText(@"读取失败", @"Read failed"), error.localizedDescription);
        else {
            [self connectionChanged];
            self.textView.text = [response[@"data"] isKindOfClass:NSString.class] ? response[@"data"] : CLPretty(response[@"data"]);
        }
    });
}
@end

@interface CLSettingSwitch : UISwitch
@property(copy) NSString* key;
@end
@implementation CLSettingSwitch
@end

@interface CLHistoryChart : UIView
@property(strong) NSArray* samples;
@property(copy) NSString* metric;
@end
@implementation CLHistoryChart
- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];
    CGRect plot = CGRectInset(self.bounds, 40, 30);
    plot.origin.x = 48;
    plot.size.width = MAX(1, self.bounds.size.width - 66);
    double minimum = [self.metric isEqualToString:@"CurrentCapacity"] ? 0 : DBL_MAX;
    double maximum = [self.metric isEqualToString:@"CurrentCapacity"] ? 100 : -DBL_MAX;
    NSMutableArray* values = [NSMutableArray new];
    for (NSDictionary* sample in self.samples) {
        NSNumber* raw = sample[self.metric];
        if (!raw) continue;
        double value = raw.doubleValue / ([self.metric isEqualToString:@"Temperature"] ? 100 : 1);
        if (!isfinite(value)) continue;
        [values addObject:@{@"value":@(value), @"time":sample[@"UpdateTime"] ?: @0}];
        minimum = MIN(minimum, value);
        maximum = MAX(maximum, value);
    }
    if (!values.count) {
        [CLText(@"暂无图表数据", @"No chart data") drawAtPoint:CGPointMake(48, 90) withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:15], NSForegroundColorAttributeName:CLForeground()}];
        return;
    }
    if (maximum <= minimum) { minimum -= 1; maximum += 1; }
    UIColor* gridColor = [UIColor colorWithWhite:0.5 alpha:0.2];
    NSDictionary* textStyle = @{NSFontAttributeName:[UIFont systemFontOfSize:11], NSForegroundColorAttributeName:CLForeground()};
    for (int i = 0; i <= 4; i++) {
        CGFloat y = CGRectGetMaxY(plot) - plot.size.height * i / 4;
        UIBezierPath* grid = [UIBezierPath bezierPath];
        [grid moveToPoint:CGPointMake(plot.origin.x, y)];
        [grid addLineToPoint:CGPointMake(CGRectGetMaxX(plot), y)];
        [gridColor setStroke];
        [grid stroke];
        [[NSString stringWithFormat:@"%.0f", minimum + (maximum - minimum) * i / 4] drawAtPoint:CGPointMake(5, y - 7) withAttributes:textStyle];
    }
    double firstTime = [values.firstObject[@"time"] doubleValue];
    double lastTime = [values.lastObject[@"time"] doubleValue];
    UIBezierPath* line = [UIBezierPath bezierPath];
    for (NSUInteger i = 0; i < values.count; i++) {
        double position = lastTime > firstTime ? ([values[i][@"time"] doubleValue] - firstTime) / (lastTime - firstTime) : (double)i / MAX(1, values.count - 1);
        CGPoint point = CGPointMake(plot.origin.x + plot.size.width * position, CGRectGetMaxY(plot) - plot.size.height * ([values[i][@"value"] doubleValue] - minimum) / (maximum - minimum));
        if (i == 0) [line moveToPoint:point]; else [line addLineToPoint:point];
        if (values.count == 1) {
            [UIColor.systemBlueColor setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(point.x - 3, point.y - 3, 6, 6)] fill];
        }
    }
    [UIColor.systemBlueColor setStroke];
    line.lineWidth = 2;
    [line stroke];
    NSDateFormatter* date = [NSDateFormatter new];
    date.dateFormat = @"MM/dd HH:mm";
    [[date stringFromDate:[NSDate dateWithTimeIntervalSince1970:firstTime]] drawAtPoint:CGPointMake(plot.origin.x, CGRectGetMaxY(plot) + 8) withAttributes:textStyle];
    NSString* last = [date stringFromDate:[NSDate dateWithTimeIntervalSince1970:lastTime]];
    [last drawAtPoint:CGPointMake(CGRectGetMaxX(plot) - [last sizeWithAttributes:textStyle].width, CGRectGetMaxY(plot) + 8) withAttributes:textStyle];
    self.accessibilityLabel = [NSString stringWithFormat:CLText(@"趋势图，%lu 条记录，最低 %.1f，最高 %.1f", @"Trend, %lu records, minimum %.1f, maximum %.1f"), (unsigned long)values.count, minimum, maximum];
}
@end

static NSDictionary* CLRow(NSString* title, NSString* key, NSString* type) {
    return @{@"title":title, @"key":key, @"type":type};
}

@interface CLNativeController : UITableViewController
@property NSInteger page;
@property(strong) NSDictionary* config;
@property(strong) NSDictionary* battery;
@property(strong) NSDictionary* chargingExplanation;
@property(strong) NSDictionary* storage;
@property(strong) NSArray* history;
@property(strong) NSArray* sections;
@property(strong) NSTimer* timer;
@property(copy) NSString* serviceMessage;
@property BOOL refreshing;
@property BOOL changing;
@property BOOL exporting;
@property BOOL visible;
@property BOOL hasUPS;
@property BOOL serviceAvailable;
@property NSInteger historyPeriod;
@property(strong) UISegmentedControl* historySelector;
@property(strong) UISegmentedControl* chartSelector;
@property(strong) CLHistoryChart* chart;
- (void)refresh;
@end

@implementation CLNativeController
- (instancetype)initWithPage:(NSInteger)page {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        self.page = page;
        self.config = @{};
        self.battery = @{};
        self.storage = @{};
        self.history = @[];
        self.serviceMessage = CLText(@"正在连接后台服务…", @"Connecting to the background service…");
        NSArray* titles = @[CLText(@"充电", @"Charging"), CLText(@"设置", @"Settings"), CLText(@"历史", @"History"), CLText(@"诊断与导出", @"Diagnostics")];
        self.title = titles[page];
        UIImage* icon = [[UIImage imageNamed:@[@"TabCharging", @"TabSettings", @"TabHistory", @"TabDiagnostics"][page]] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:self.title image:icon tag:page];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = CLBackground();
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 54;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)];
    if (self.page == 2) {
        self.historySelector = [[UISegmentedControl alloc] initWithItems:@[CLText(@"5 分钟", @"5 min"), CLText(@"小时", @"Hour"), CLText(@"天", @"Day"), CLText(@"月", @"Month")]];
        self.historySelector.selectedSegmentIndex = 0;
        [self.historySelector addTarget:self action:@selector(changeHistory:) forControlEvents:UIControlEventValueChanged];
        self.navigationItem.titleView = self.historySelector;
        UIView* header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 260)];
        self.chartSelector = [[UISegmentedControl alloc] initWithItems:@[CLText(@"电量 %", @"Capacity %"), CLText(@"温度 °C", @"Temperature °C"), CLText(@"电流 mA", @"Current mA")]];
        self.chartSelector.frame = CGRectMake(16, 12, header.bounds.size.width - 32, 32);
        self.chartSelector.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.chartSelector.selectedSegmentIndex = 0;
        [self.chartSelector addTarget:self action:@selector(updateChart) forControlEvents:UIControlEventValueChanged];
        [header addSubview:self.chartSelector];
        self.chart = [[CLHistoryChart alloc] initWithFrame:CGRectMake(0, 48, header.bounds.size.width, 212)];
        self.chart.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.chart.backgroundColor = UIColor.clearColor;
        self.chart.isAccessibilityElement = YES;
        [header addSubview:self.chart];
        self.tableView.tableHeaderView = header;
    }
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resignedActive) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(serviceConnectionChanged) name:CLServiceConnectionChanged object:nil];
    [self serviceConnectionChanged];
    [self rebuild];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.visible = YES;
    [self becameActive];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.page == 2) {
        CGFloat width = self.tableView.bounds.size.width;
        self.chartSelector.frame = CGRectMake(16, 12, MAX(1, width - 32), 32);
        self.chart.frame = CGRectMake(0, 48, width, 212);
    }
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.visible = NO;
    [self resignedActive];
}
- (void)dealloc {
    [self.timer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)becameActive {
    if (!self.visible) return;
    [CLServiceMonitor.shared start];
    [self refresh];
    [self startTimer];
}
- (void)resignedActive { [self.timer invalidate]; self.timer = nil; }
- (void)serviceConnectionChanged {
    CLServiceMonitor* monitor = CLServiceMonitor.shared;
    self.navigationItem.prompt = monitor.title;
    BOOL wasAvailable = self.serviceAvailable;
    self.serviceAvailable = monitor.checked && monitor.connected;
    self.serviceMessage = monitor.title;
    if (self.isViewLoaded) [self rebuild];
    if (self.visible && !wasAvailable && self.serviceAvailable) [self refresh];
}
- (void)startTimer {
    [self.timer invalidate];
    if (!self.visible || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSTimeInterval interval = MAX(1, [self.config[@"update_freq"] doubleValue]);
    if (self.page > 1) interval = MAX(30, interval);
    if (!self.serviceAvailable) interval = 2;
    __weak CLNativeController* weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:interval repeats:YES block:^(NSTimer* timer) { [weakSelf refresh]; }];
}
- (void)changeHistory:(UISegmentedControl*)control {
    self.historyPeriod = control.selectedSegmentIndex;
    [self.chartSelector removeAllSegments];
    NSArray* labels = self.historyPeriod < 2 ? @[CLText(@"电量 %", @"Capacity %"), CLText(@"温度 °C", @"Temperature °C"), CLText(@"电流 mA", @"Current mA")] : @[CLText(@"容量 mAh", @"Capacity mAh"), CLText(@"循环次数", @"Cycles")];
    for (NSUInteger i = 0; i < labels.count; i++) [self.chartSelector insertSegmentWithTitle:labels[i] atIndex:i animated:NO];
    self.chartSelector.selectedSegmentIndex = 0;
    [self refresh];
}
- (void)updateChart {
    NSArray* keys = self.historyPeriod < 2 ? @[@"CurrentCapacity", @"Temperature", @"Amperage"] : @[@"NominalChargeCapacity", @"CycleCount"];
    self.chart.metric = keys[MAX(0, self.chartSelector.selectedSegmentIndex)];
    self.chart.samples = self.history;
    [self.chart setNeedsDisplay];
}
- (void)refresh {
    if (self.refreshing || self.changing) return;
    self.refreshing = YES;
    CLRequest(@{@"api":@"get_conf"}, ^(NSDictionary* response, NSError* error) {
        if (error) {
            if (self.page == 3) {
                self.storage = CLStorageInfo();
                self.config = CLReadConfiguration(nil) ?: self.config;
            }
            [self finishRefresh:error];
            return;
        }
        self.config = response[@"data"] ?: @{};
        NSDictionary* request;
        if (self.page == 2) {
            NSString* table = @[@"min5", @"hour", @"day", @"month"][self.historyPeriod];
            request = @{@"api":@"get_statistics", @"conf":@{table:@{@"n":@200, @"last_id":@0}}};
        } else if (self.page == 3) request = @{@"api":@"get_storage_info"};
        else request = @{@"api":@"get_bat_info"};
        CLRequest(request, ^(NSDictionary* result, NSError* readError) {
            if (!readError) {
                if (self.page == 2) self.history = [result[@"data"] allValues].firstObject ?: @[];
                else if (self.page == 3) self.storage = result[@"data"] ?: @{};
                else {
                    self.battery = result[@"data"] ?: @{};
                    self.chargingExplanation = result[@"charging_explanation"] ?: @{};
                    self.hasUPS = result[@"data_ups"] != nil;
                }
            }
            [self finishRefresh:readError];
        });
    });
}
- (void)finishRefresh:(NSError*)error {
    self.refreshing = NO;
    self.serviceAvailable = CLServiceMonitor.shared.connected && CLServiceMonitor.shared.checked;
    [self.refreshControl endRefreshing];
    self.serviceMessage = error ? error.localizedDescription : CLServiceMonitor.shared.title;
    [self rebuild];
    [self startTimer];
}
- (void)rebuild {
    if (self.page == 0) {
        self.sections = @[
            @{ @"title":CLText(@"电池状态", @"Battery status"), @"rows":@[
                CLRow(CLText(@"电量", @"Capacity"), @"CurrentCapacity", @"battery"),
                CLRow(CLText(@"温度", @"Temperature"), @"Temperature", @"battery"),
                CLRow(CLText(@"电流", @"Current"), @"Amperage", @"battery"),
                CLRow(CLText(@"正在充电（手动控制）", @"Charging (manual control)"), @"IsCharging", @"manual"),
                CLRow(CLText(@"电源输入（手动控制）", @"Power inflow (manual control)"), @"ExternalConnected", @"manual"),
                CLRow(CLText(@"自动控制状态", @"Automatic control"), @"reason", @"reason"),
                CLRow(CLText(@"电池与电源详细信息", @"Battery and adapter details"), @"batteryDetails", @"action") ]},
            @{ @"title":CLText(@"自动充电", @"Automatic charging"), @"rows":@[
                CLRow(CLText(@"启用自动控制", @"Enable automatic control"), @"enable", @"switch"),
                CLRow(CLText(@"触发模式", @"Trigger mode"), @"mode", @"choice"),
                CLRow(CLText(@"开始充电下限", @"Start charging at"), @"charge_below", @"number"),
                CLRow(CLText(@"停止充电上限", @"Stop charging at"), @"charge_above", @"number") ]},
            @{ @"title":CLText(@"温度控制", @"Temperature control"), @"rows":@[
                CLRow(CLText(@"启用温控", @"Enable temperature control"), @"enable_temp", @"switch"),
                CLRow(CLText(@"温度单位", @"Temperature unit"), @"temp_mode", @"choice"),
                CLRow(CLText(@"开始充电温度", @"Resume temperature"), @"charge_temp_below", @"number"),
                CLRow(CLText(@"停止充电温度", @"Stop temperature"), @"charge_temp_above", @"number") ]} ];
    } else if (self.page == 1) {
        self.sections = @[
            @{ @"title":CLText(@"显示", @"Display"), @"rows":@[
                CLRow(CLText(@"界面更新频率", @"Refresh interval"), @"update_freq", @"choice"),
                CLRow(CLText(@"悬浮窗", @"Floating window"), @"floatwnd", @"switch"),
                CLRow(CLText(@"悬浮窗自动隐藏", @"Auto-hide floating window"), @"floatwnd_auto", @"switch"),
                CLRow(CLText(@"禁用系统优化充电", @"Disable optimized charging"), @"disable_smart_charge", @"switch") ]},
            @{ @"title":CLText(@"充电控制选项", @"Charging options"), @"rows":@[
                CLRow(@"SmartBattery", @"adv_prefer_smart", @"switch"),
                CLRow(CLText(@"智能停充", @"Predictive charging inhibit"), @"adv_predictive_inhibit_charge", @"switch"),
                CLRow(CLText(@"停充时自动禁流", @"Disable inflow when stopped"), @"adv_disable_inflow", @"switch"),
                CLRow(CLText(@"自动限流", @"Automatic inflow limit"), @"adv_limit_inflow", @"switch"),
                CLRow(CLText(@"限流模拟等级", @"Inflow thermal level"), @"adv_limit_inflow_mode", @"choice"),
                CLRow(CLText(@"默认高温模拟", @"Default thermal simulation"), @"adv_def_thermal_mode", @"choice"),
                CLRow(CLText(@"锁定高温模拟", @"Lock thermal simulation"), @"adv_thermal_mode_lock", @"switch"),
                CLRow(CLText(@"峰值性能模拟", @"Peak performance simulation"), @"ppm_simulate_mode", @"choice") ]},
            @{ @"title":CLText(@"充电时节能", @"Power saving while charging"), @"rows":@[
                CLRow(CLText(@"启用充电节能", @"Enable charging power saving"), @"acc_charge", @"switch"),
                CLRow(CLText(@"开启飞行模式", @"Enable airplane mode"), @"acc_charge_airmode", @"switch"),
                CLRow(CLText(@"关闭 Wi-Fi", @"Turn off Wi-Fi"), @"acc_charge_wifi", @"switch"),
                CLRow(CLText(@"关闭蓝牙", @"Turn off Bluetooth"), @"acc_charge_blue", @"switch"),
                CLRow(CLText(@"充电时屏幕亮度", @"Screen brightness while charging"), @"acc_charge_bright", @"number"),
                CLRow(CLText(@"开启低电量模式", @"Enable Low Power Mode"), @"acc_charge_lpm", @"switch") ]},
            @{ @"title":CLText(@"使用说明", @"Help"), @"rows":@[CLRow(CLText(@"查看说明", @"Read help"), @"help", @"action")]}
        ];
    } else if (self.page == 2) {
        [self updateChart];
        NSMutableArray* rows = [NSMutableArray new];
        for (NSDictionary* sample in self.history.reverseObjectEnumerator) [rows addObject:@{@"sample":sample, @"type":@"history"}];
        self.sections = @[@{@"title":self.history.count ? CLText(@"最近 200 条记录", @"Latest 200 records") : CLText(@"暂无记录，电池事件发生后会自动保存。", @"No records yet. Battery events are saved automatically."), @"rows":rows}];
    } else {
        NSMutableArray* exports = [NSMutableArray new];
        for (NSDictionary* saved in self.storage[@"exports"]) [exports addObject:@{@"title":saved[@"name"], @"type":@"export", @"export":saved}];
        self.sections = @[
            @{ @"title":CLText(@"查看与导出", @"Inspect and export"), @"rows":@[
                CLRow(CLText(@"查看日志", @"View log"), @"log", @"action"),
                CLRow(CLText(@"查看已保存配置", @"View saved configuration"), @"config", @"action"),
                CLRow(CLText(@"导出日志与配置", @"Export log and configuration"), @"export", @"action") ]},
            @{ @"title":CLText(@"设备持久存储", @"Persistent device storage"), @"rows":@[
                CLRow(CLText(@"保存位置", @"Storage location"), @"directory", @"storage"),
                CLRow(CLText(@"配置历史版本", @"Configuration revisions"), @"configuration_revisions", @"storage") ]},
            @{ @"title":CLText(@"已保存导出（点击再次分享）", @"Saved exports (tap to share)"), @"rows":exports} ];
    }
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView { return self.sections.count; }
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section { return [self.sections[section][@"rows"] count]; }
- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section { return self.sections[section][@"title"]; }
- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        if (self.page == 0 && !self.serviceAvailable && self.battery.count) return CLText(@"服务未连接；电池信息为上次记录，当前状态未知。", @"Service unavailable; battery values are from the last report. Current state is unknown.");
        return self.serviceMessage;
    }
    if (self.page == 0 && section == 1) return CLText(@"边缘触发：电量 ≤ 下限开始充电，电量 ≥ 上限停止充电。温度上限优先阻止充电。", @"Edge trigger: charge at or below the lower threshold; stop at or above the upper threshold. The temperature limit takes priority.");
    if (self.page == 0 && section == 2) return CLText(@"边缘触发模式仅在低电量条件下恢复充电；开始充电温度用于插电即充模式。", @"In edge mode, charging resumes only at the capacity threshold. Resume temperature applies to plug-and-charge mode.");
    if (self.page == 3 && section == 1) return CLText(@"启动时读取已有配置并追加日志；配置修改保留历史版本，每次导出单独保存。", @"Startup reads the saved configuration and appends logs. Changes retain revisions; every export is stored separately.");
    return nil;
}
- (NSString*)controlReason {
    if (!self.serviceAvailable) return CLText(@"服务未连接，自动控制状态未知", @"Service unavailable; automatic state unknown");
    return self.chargingExplanation[CLText(@"title_zh", @"title_en")] ?: CLText(@"暂无原因数据，请更新后台服务", @"No explanation available; update the service");
}
- (NSArray*)choicesForKey:(NSString*)key {
    if ([key isEqualToString:@"mode"]) return @[@[@"charge_on_plug", CLText(@"插电即充", @"Plug and charge")], @[@"edge_trigger", CLText(@"边缘触发", @"Edge trigger")]];
    if ([key isEqualToString:@"temp_mode"]) return @[@[@0,@"°C"], @[@1,@"°F"]];
    if ([key isEqualToString:@"update_freq"]) return @[@[@1,CLText(@"1 秒", @"1 second")], @[@20,CLText(@"20 秒", @"20 seconds")], @[@60,CLText(@"1 分钟", @"1 minute")], @[@600,CLText(@"10 分钟", @"10 minutes")]];
    return @[@[@"off",CLText(@"关闭", @"Off")], @[@"nominal",CLText(@"正常", @"Nominal")], @[@"light",CLText(@"轻度", @"Light")], @[@"moderate",CLText(@"中度", @"Moderate")], @[@"heavy",CLText(@"重度", @"Heavy")]];
}
- (NSString*)valueForRow:(NSDictionary*)row {
    NSString* key = row[@"key"];
    NSString* type = row[@"type"];
    if ([type isEqualToString:@"reason"]) return [self controlReason];
    if ([type isEqualToString:@"storage"]) return [self.storage[key] description] ?: @"—";
    if ([type isEqualToString:@"battery"]) {
        NSNumber* value = self.battery[key];
        if (!value) return @"—";
        if ([key isEqualToString:@"CurrentCapacity"]) return [NSString stringWithFormat:@"%@ %%", value];
        if ([key isEqualToString:@"Amperage"]) return [NSString stringWithFormat:@"%@ mA", value];
        double celsius = value.doubleValue / 100;
        return [self.config[@"temp_mode"] intValue] == 1 ? [NSString stringWithFormat:@"%.1f °F", celsius * 1.8 + 32] : [NSString stringWithFormat:@"%.1f °C", celsius];
    }
    if ([type isEqualToString:@"choice"]) {
        for (NSArray* choice in [self choicesForKey:key]) if ([choice[0] isEqual:self.config[key]]) return choice[1];
    }
    if ([type isEqualToString:@"number"]) {
        if ([key hasPrefix:@"charge_temp"]) return [NSString stringWithFormat:@"%@ %@", self.config[key] ?: @"—", [self.config[@"temp_mode"] intValue] == 1 ? @"°F" : @"°C"];
        if ([key isEqualToString:@"acc_charge_bright"]) return [NSString stringWithFormat:@"%.0f %%", [self.config[key] doubleValue] * 100];
        return [NSString stringWithFormat:@"%@ %%", self.config[key] ?: @"—"];
    }
    return @"";
}
- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    NSDictionary* row = self.sections[indexPath.section][@"rows"][indexPath.row];
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = row[@"title"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.text = [self valueForRow:row];
    NSString* type = row[@"type"];
    if ([type isEqualToString:@"switch"] || [type isEqualToString:@"manual"]) {
        CLSettingSwitch* control = [CLSettingSwitch new];
        control.key = row[@"key"];
        control.on = [([type isEqualToString:@"manual"] ? self.battery : self.config)[control.key] boolValue];
        control.enabled = self.serviceAvailable && !self.changing && !self.refreshing;
        control.accessibilityLabel = row[@"title"];
        [control addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = control;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"history"]) {
        NSDictionary* sample = row[@"sample"];
        NSDate* date = [NSDate dateWithTimeIntervalSince1970:[sample[@"UpdateTime"] doubleValue]];
        cell.textLabel.text = [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
        cell.detailTextLabel.text = sample[@"CurrentCapacity"] ? [NSString stringWithFormat:CLText(@"电量 %@%% · %.1f°C · %@ mA · %@", @"%@%% · %.1f°C · %@ mA · %@"), sample[@"CurrentCapacity"], [sample[@"Temperature"] doubleValue] / 100, sample[@"Amperage"] ?: @"—", [sample[@"IsCharging"] boolValue] ? CLText(@"充电", @"Charging") : CLText(@"未充电", @"Not charging")] : [NSString stringWithFormat:CLText(@"循环次数 %@ · 容量 %@ mAh", @"Cycles %@ · Capacity %@ mAh"), sample[@"CycleCount"] ?: @"—", sample[@"NominalChargeCapacity"] ?: @"—"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if ([@[@"choice", @"number", @"action", @"export", @"reason"] containsObject:type]) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (self.exporting && ([row[@"key"] isEqualToString:@"export"] || [type isEqualToString:@"export"])) {
            UIActivityIndicatorView* spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
            [spinner startAnimating];
            cell.accessoryView = spinner;
        }
    }
    else cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}
- (void)toggle:(CLSettingSwitch*)control {
    NSDictionary* request;
    if ([control.key isEqualToString:@"IsCharging"] || [control.key isEqualToString:@"ExternalConnected"]) {
        request = @{@"api":[control.key isEqualToString:@"IsCharging"] ? @"set_charge_status" : @"set_inflow_status", @"flag":@(control.on)};
    } else request = @{@"api":@"set_conf", @"key":control.key, @"val":@(control.on)};
    [self sendChange:request];
}
- (void)sendChange:(NSDictionary*)request {
    if (self.changing) return;
    self.changing = YES;
    [self rebuild];
    CLRequest(request, ^(NSDictionary* response, NSError* error) {
        self.changing = NO;
        if (error) CLAlert(self, CLText(@"设置失败", @"Change failed"), error.localizedDescription);
        if ([request[@"key"] isEqualToString:@"adv_prefer_smart"] && !error) {
            self.serviceMessage = CLText(@"后台服务正在重启…", @"Restarting the service…");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self refresh]; });
        } else [self refresh];
    });
}
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary* row = self.sections[indexPath.section][@"rows"][indexPath.row];
    NSString* key = row[@"key"];
    NSString* type = row[@"type"];
    if (self.changing) return;
    if ([type isEqualToString:@"choice"]) {
        UIAlertController* picker = [UIAlertController alertControllerWithTitle:row[@"title"] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSArray* choice in [self choicesForKey:key]) [picker addAction:[UIAlertAction actionWithTitle:choice[1] style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            NSMutableDictionary* request = [@{@"api":@"set_conf", @"key":key, @"val":choice[0]} mutableCopy];
            if ([key isEqualToString:@"temp_mode"] && ![self.config[key] isEqual:choice[0]]) {
                double below = [self.config[@"charge_temp_below"] doubleValue];
                double above = [self.config[@"charge_temp_above"] doubleValue];
                request[@"vals"] = [choice[0] intValue] == 1 ? @[@(below * 1.8 + 32), @(above * 1.8 + 32)] : @[@((below - 32) / 1.8), @((above - 32) / 1.8)];
            }
            [self sendChange:request];
        }]];
        [picker addAction:[UIAlertAction actionWithTitle:CLText(@"取消", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
        picker.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
        picker.popoverPresentationController.sourceRect = [tableView cellForRowAtIndexPath:indexPath].bounds;
        [self presentViewController:picker animated:YES completion:nil];
    } else if ([type isEqualToString:@"number"]) [self editNumber:row];
    else if ([type isEqualToString:@"export"]) [self shareExport:row[@"export"]];
    else if ([type isEqualToString:@"reason"]) {
        NSString* detail = self.serviceAvailable ? self.chargingExplanation[CLText(@"detail_zh", @"detail_en")] : CLText(@"后台服务未连接，无法判断当前未充电原因。请查看连接状态和日志。", @"The service is unavailable; the current cause cannot be determined. Check connection status and logs.");
        CLAlert(self, [self controlReason], detail ?: CLText(@"请更新后台服务并刷新。", @"Update the service and refresh."));
    }
    else if ([type isEqualToString:@"history"]) [self showText:CLPretty(row[@"sample"]) title:CLText(@"记录详情", @"Record details") api:nil];
    else if ([key isEqualToString:@"log"]) [self showText:nil title:CLText(@"日志（最近 256 KB）", @"Log (latest 256 KB)") api:@"get_log"];
    else if ([key isEqualToString:@"config"]) [self showText:nil title:CLText(@"已保存配置", @"Saved configuration") api:@"get_saved_conf"];
    else if ([key isEqualToString:@"batteryDetails"]) [self showText:nil title:CLText(@"电池与电源信息", @"Battery and adapter") api:@"get_bat_info"];
    else if ([key isEqualToString:@"export"]) [self createExport];
    else if ([key isEqualToString:@"help"]) {
        NSString* path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:[NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"] ? @"www/help_zh_CN.md" : @"www/help_en.md"];
        [self showText:[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] title:CLText(@"使用说明", @"Help") api:nil];
    }
}
- (void)editNumber:(NSDictionary*)row {
    NSString* key = row[@"key"];
    BOOL brightness = [key isEqualToString:@"acc_charge_bright"];
    UIAlertController* editor = [UIAlertController alertControllerWithTitle:row[@"title"] message:brightness ? CLText(@"输入 0–100，0 表示关闭亮度调整。", @"Enter 0–100. Zero disables brightness adjustment.") : nil preferredStyle:UIAlertControllerStyleAlert];
    [editor addTextFieldWithConfigurationHandler:^(UITextField* input) {
        input.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        input.text = [NSString stringWithFormat:@"%g", [self.config[key] doubleValue] * (brightness ? 100 : 1)];
        input.accessibilityLabel = row[@"title"];
    }];
    [editor addAction:[UIAlertAction actionWithTitle:CLText(@"取消", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [editor addAction:[UIAlertAction actionWithTitle:CLText(@"保存", @"Save") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        NSString* text = editor.textFields.firstObject.text;
        NSScanner* scanner = [NSScanner scannerWithString:text];
        double value = 0;
        BOOL valid = [scanner scanDouble:&value] && scanner.isAtEnd && isfinite(value);
        BOOL temperature = [key hasPrefix:@"charge_temp"];
        if (temperature) {
            double celsius = [self.config[@"temp_mode"] intValue] == 1 ? (value - 32) / 1.8 : value;
            valid = valid && celsius >= 0 && celsius <= 60;
        } else valid = valid && value >= 0 && value <= 100;
        if ([key isEqualToString:@"charge_below"]) valid = valid && floor(value) == value && value < [self.config[@"charge_above"] doubleValue];
        if ([key isEqualToString:@"charge_above"]) valid = valid && floor(value) == value && value > [self.config[@"charge_below"] doubleValue];
        if ([key isEqualToString:@"charge_temp_below"]) valid = valid && value < [self.config[@"charge_temp_above"] doubleValue];
        if ([key isEqualToString:@"charge_temp_above"]) valid = valid && value > [self.config[@"charge_temp_below"] doubleValue];
        if (!valid) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                CLAlert(self, CLText(@"数值无效", @"Invalid value"), CLText(@"电量需为 0–100 的整数，温度需为 0–60°C，且下限必须小于上限。", @"Capacity must be an integer from 0–100, temperature 0–60°C, and the lower threshold must be below the upper threshold."));
            });
            return;
        }
        [self sendChange:@{@"api":@"set_conf", @"key":key, @"val":@(brightness ? value / 100 : value)}];
    }]];
    [self presentViewController:editor animated:YES completion:nil];
}
- (void)showText:(NSString*)text title:(NSString*)title api:(NSString*)api {
    CLTextController* controller = [CLTextController new];
    controller.title = title;
    controller.content = text;
    controller.api = api;
    [self.navigationController pushViewController:controller animated:YES];
}
- (void)createExport {
    if (self.exporting) return;
    self.exporting = YES;
    [self rebuild];
    if (CLServiceMonitor.shared.checked && !CLServiceMonitor.shared.connected) {
        NSError* error = nil;
        NSDictionary* saved = CLCreateExport(self.battery, &error);
        if (!saved) {
            self.exporting = NO;
            [self rebuild];
            CLAlert(self, CLText(@"导出失败", @"Export failed"), error.localizedDescription ?: @"Export unavailable");
        } else {
            CLConnectionLog([NSString stringWithFormat:@"diagnostics exported locally while service unavailable: %@", saved[@"directory"]]);
            CLDownloadExport(self, saved, ^{ self.exporting = NO; [self rebuild]; [self refresh]; });
        }
        return;
    }
    CLRequest(@{@"api":@"export_diagnostics"}, ^(NSDictionary* response, NSError* error) {
        if (error) { self.exporting = NO; [self rebuild]; CLAlert(self, CLText(@"导出失败", @"Export failed"), error.localizedDescription); return; }
        CLDownloadExport(self, response[@"data"], ^{ self.exporting = NO; [self rebuild]; [self refresh]; });
    });
}
- (void)shareExport:(NSDictionary*)exportInfo {
    if (self.exporting) return;
    self.exporting = YES;
    [self rebuild];
    CLDownloadExport(self, exportInfo, ^{ self.exporting = NO; [self rebuild]; });
}
@end

UIViewController* CLCreateNativeInterface(void) {
    [CLServiceMonitor.shared start];
    UITabBarController* tabs = [UITabBarController new];
    NSMutableArray* pages = [NSMutableArray new];
    for (NSInteger page = 0; page < 4; page++) {
        UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:[[CLNativeController alloc] initWithPage:page]];
        if (@available(iOS 11.0, *)) navigation.navigationBar.prefersLargeTitles = page != 2;
        [pages addObject:navigation];
    }
    tabs.viewControllers = pages;
    return tabs;
}

@implementation CLNativeHUD {
    UILabel* label;
    NSTimer* timer;
    BOOL enabled;
    BOOL busy;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.86];
        self.layer.cornerRadius = 12;
        self.clipsToBounds = YES;
        label = [[UILabel alloc] initWithFrame:self.bounds];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 3;
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        label.text = @"CL\n…";
        [self addSubview:label];
        [self addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        self.accessibilityLabel = CLText(@"充电悬浮窗，点击切换自动控制", @"Charging overlay. Tap to toggle automatic control.");
    }
    return self;
}
- (void)startUpdating {
    [self stopUpdating];
    __weak CLNativeHUD* weakSelf = self;
    timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer* t) { [weakSelf update]; }];
    [self update];
}
- (void)stopUpdating { [timer invalidate]; timer = nil; }
- (void)dealloc { [timer invalidate]; }
- (void)update {
    if (busy) return;
    busy = YES;
    CLRequest(@{@"api":@"get_bat_info"}, ^(NSDictionary* response, NSError* error) {
        self->busy = NO;
        if (error) { self->label.text = @"CL\n离线 / Offline"; return; }
        self->enabled = [response[@"enable"] boolValue];
        NSDictionary* battery = response[@"data"];
        self->label.text = [NSString stringWithFormat:@"%@%%  %.1f°C\n%@ mA\n%@", battery[@"CurrentCapacity"] ?: @"—", [battery[@"Temperature"] doubleValue] / 100, battery[@"Amperage"] ?: @"—", self->enabled ? @"CL ON" : @"CL OFF"];
        self.accessibilityValue = self->label.text;
    });
}
- (void)toggle {
    CLRequest(@{@"api":@"set_conf", @"key":@"enable", @"val":@(!enabled)}, ^(NSDictionary* response, NSError* error) { [self update]; });
}
@end
