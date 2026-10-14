#import "watchdog.h"
#import "storage.h"
#include <sys/file.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <dlfcn.h>
#include <limits.h>

static void logWatchdog(NSString* message) {
    NSDateFormatter* date = [NSDateFormatter new];
    date.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    CLAppendLog([NSString stringWithFormat:@"%@ watchdog: %@\n", [date stringFromDate:NSDate.date],message],nil);
}
static NSString* leasePath(NSString* role) {
    return [@CL_DATA_DIRECTORY stringByAppendingPathComponent:[role stringByAppendingString:@".lock"]];
}
static NSDictionary* processIdentity(pid_t pid) {
    if (pid <= 1) return nil;
    int mib[] = {CTL_KERN,KERN_PROC,KERN_PROC_PID,pid};
    struct kinfo_proc proc = {};
    size_t length = sizeof(proc);
    if (sysctl(mib,4,&proc,&length,NULL,0) || length != sizeof(proc) || proc.kp_proc.p_pid != pid) return nil;
    auto pathForPID = (int (*)(int,void*,uint32_t))dlsym(RTLD_DEFAULT,"proc_pidpath");
    char path[4096] = {};
    if (!pathForPID || pathForPID(pid,path,sizeof(path)) <= 0) return nil;
    return @{@"pid":@(pid), @"executable":[@(path) stringByResolvingSymlinksInPath], @"start_sec":@(proc.kp_proc.p_starttime.tv_sec), @"start_usec":@(proc.kp_proc.p_starttime.tv_usec)};
}
static BOOL sameProcess(NSDictionary* saved, NSDictionary* current) {
    if (!saved || !current) return NO;
    for (NSString* key in @[@"pid",@"executable",@"start_sec",@"start_usec"]) if (![saved[key] isEqual:current[key]]) return NO;
    return YES;
}
static NSString* roleExecutable(NSString* role) {
    NSString* own=processIdentity(getpid())[@"executable"];
    if (!own) return nil;
    if ([@[@"ChargeLimiterDaemon",@"ChargeLimiterWatchdog"] containsObject:own.lastPathComponent]) {
        return [own.stringByDeletingLastPathComponent stringByAppendingPathComponent:[role isEqual:@"service"] ? @"ChargeLimiterDaemon" : @"ChargeLimiterWatchdog"];
    }
    return own; // Portable process harnesses use one executable for both roles.
}
@implementation CLProcessLease {
    int descriptor;
    NSDictionary* owner;
}
- (instancetype)init { if ((self=[super init])) descriptor=-1; return self; }
+ (instancetype)acquireRole:(NSString*)role {
    if (![@[@"service",@"watchdog"] containsObject:role]) return nil;
    int fd = open(leasePath(role).fileSystemRepresentation,O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0640);
    if (fd < 0) return nil;
    if (flock(fd,LOCK_EX|LOCK_NB)) { close(fd); return nil; }
    CLProcessLease* lease = [self new]; lease->descriptor=fd;
    NSMutableDictionary* identity = [processIdentity(getpid()) mutableCopy] ?: [@{@"pid":@(getpid())} mutableCopy];
    identity[@"role"] = role;
    lease->owner = identity.copy;
    NSData* data = [NSJSONSerialization dataWithJSONObject:identity options:0 error:nil];
    if (ftruncate(fd,0)) return nil;
    const char* bytes=(const char*)data.bytes; size_t remaining=data.length;
    while (remaining) {
        ssize_t written=write(fd,bytes,remaining);
        if (written<0 && errno==EINTR) continue;
        if (written<=0) return nil;
        bytes+=written; remaining-=written;
    }
    return lease;
}
- (NSDictionary*)identity { return owner; }
- (void)dealloc { if (descriptor>=0) close(descriptor); }
@end
BOOL CLRoleIsLocked(NSString* role) {
    int fd=open(leasePath(role).fileSystemRepresentation,O_RDWR|O_CLOEXEC|O_NOFOLLOW);
    if (fd<0) return errno!=ENOENT; // An unreadable lease is not evidence of absence.
    BOOL locked=flock(fd,LOCK_EX|LOCK_NB)!=0;
    close(fd); return locked;
}
NSDictionary* CLActiveRoleIdentity(NSString* role) {
    if (!CLRoleIsLocked(role)) return nil;
    NSData* data=[NSData dataWithContentsOfFile:leasePath(role)];
    NSDictionary* owner=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![owner isKindOfClass:NSDictionary.class] || ![owner[@"role"] isEqual:role]) return nil;
    if (![owner[@"pid"] isKindOfClass:NSNumber.class] || ![owner[@"start_sec"] isKindOfClass:NSNumber.class] || ![owner[@"start_usec"] isKindOfClass:NSNumber.class] || ![owner[@"executable"] isKindOfClass:NSString.class]) return nil;
    NSDictionary* current=processIdentity([owner[@"pid"] intValue]);
    if (!sameProcess(owner,current) || ![current[@"executable"] isEqual:roleExecutable(role)]) return nil;
    return owner;
}
static BOOL signalOwner(NSDictionary* owner, int number) {
    pid_t pid=[owner[@"pid"] intValue];
    if (pid<=1 || pid==getpid()) return NO;
    NSDictionary* active=CLActiveRoleIdentity(@"service");
    if (!sameProcess(owner,active)) return NO;
    return kill(pid,number)==0;
}
BOOL CLStopOwnedService(NSURL* probeURL) {
    if (!CLRoleIsLocked(@"service")) return YES;
    NSDictionary* owner=CLActiveRoleIdentity(@"service");
    if (!owner) { logWatchdog(@"refusing to terminate service: process identity could not be verified"); return NO; }
    if (CLProbeService(probeURL ?: [NSURL URLWithString:@"http://127.0.0.1:1230/"],owner,nil)) return NO;
    logWatchdog([NSString stringWithFormat:@"restarting unresponsive service pid=%@",owner[@"pid"]]);
    signalOwner(owner,SIGTERM);
    for (int i=0;i<20 && CLRoleIsLocked(@"service");i++) {
        NSDictionary* current=CLActiveRoleIdentity(@"service");
        if (current && !sameProcess(owner,current)) break;
        // An exiting process can lose its proc_pidpath before its descriptors
        // close. Wait for the lease itself, not just the identity, to disappear.
        usleep(100000);
    }
    if (sameProcess(owner,CLActiveRoleIdentity(@"service"))) {
        if (signalOwner(owner,SIGKILL)) logWatchdog(@"service did not exit after SIGTERM; SIGKILL sent to verified process");
        for (int i=0;i<10 && CLRoleIsLocked(@"service");i++) {
            NSDictionary* current=CLActiveRoleIdentity(@"service");
            if (current && !sameProcess(owner,current)) break;
            usleep(100000);
        }
    }
    // A launchd successor may have acquired the lease; do not kill it.
    return !CLRoleIsLocked(@"service");
}
NSDictionary* CLProbeService(NSURL* url, NSDictionary* owner, NSString** problem) {
    if (!owner) { if (problem) *problem=@"no verified service lease"; return nil; }
    NSMutableURLRequest* request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:2];
    request.HTTPMethod=@"POST";
    request.HTTPBody=[NSJSONSerialization dataWithJSONObject:@{@"api":@"get_service_status"} options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSURLSessionConfiguration* configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest=2; configuration.timeoutIntervalForResource=2;
    NSURLSession* session=[NSURLSession sessionWithConfiguration:configuration];
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    __block NSData* body=nil; __block NSError* failure=nil; __block NSInteger status=0;
    NSURLSessionDataTask* task=[session dataTaskWithRequest:request completionHandler:^(NSData* data,NSURLResponse* response,NSError* error) {
        body=data; failure=error; status=[response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse*)response statusCode] : 0;
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    if (dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))) {
        [session invalidateAndCancel]; if (problem) *problem=@"service probe timed out"; return nil;
    }
    [session finishTasksAndInvalidate];
    NSDictionary* json=body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil;
    NSDictionary* state=[json isKindOfClass:NSDictionary.class] && [json[@"data"] isKindOfClass:NSDictionary.class] ? json[@"data"] : nil;
    BOOL valid=[json isKindOfClass:NSDictionary.class] && status==200 && [json[@"status"] isKindOfClass:NSNumber.class] && [json[@"status"] intValue]==0 && [state[@"status"] isEqual:@"running"] && [state[@"instance"] isKindOfClass:NSString.class] && [state[@"instance"] length]>0 && [state[@"pid"] isKindOfClass:NSNumber.class] && [state[@"pid"] intValue]==[owner[@"pid"] intValue];
    if (!valid) { if (problem) *problem=failure.localizedDescription ?: @"invalid response or service PID mismatch"; return nil; }
    return state;
}
@implementation CLWatchdogRecovery {
    NSUInteger failures, attempts;
    NSTimeInterval nextRetry, healthySince;
    BOOL previouslyHealthy, fallbackAttempted;
}
- (NSArray<NSString*>*)observeHealthy:(BOOL)healthy atUptime:(NSTimeInterval)time {
    if (healthy) {
        failures=0;
        if (!previouslyHealthy) healthySince=time;
        previouslyHealthy=YES;
        if (time-healthySince>=30) { attempts=0; nextRetry=0; fallbackAttempted=NO; }
        return @[];
    }
    previouslyHealthy=NO;
    failures=MIN(failures+1,3u);
    if (failures<3 || time<nextRetry) return @[];
    NSMutableArray* actions=[NSMutableArray new];
    if (attempts>=3 && !fallbackAttempted) [actions addObject:@"fallback"];
    [actions addObject:@"restart"];
    attempts++;
    NSTimeInterval delay=attempts==1 ? 10 : attempts==2 ? 20 : attempts==3 ? 40 : 120;
    nextRetry=time+delay;
    return actions;
}
- (void)recordFallbackAttempt { fallbackAttempted=YES; }
- (NSDictionary*)state { return @{@"consecutive_failures":@(failures),@"restart_attempts":@(attempts),@"next_retry_uptime":@(nextRetry),@"fallback_attempted":@(fallbackAttempted)}; }
@end
static volatile sig_atomic_t stopping=0;
static void stopWatchdog(int number) { stopping=number; }
int CLRunWatchdog(int (^restart)(void), int (^restore)(void), NSURL* probeURL) {
    CLProcessLease* lease=[CLProcessLease acquireRole:@"watchdog"];
    if (!lease) return 0;
    // Keep the lease alive until the monitoring loop exits.
    CLProcessLease* heldLease __attribute__((objc_precise_lifetime))=lease;
    signal(SIGHUP,SIG_IGN); signal(SIGTERM,stopWatchdog); signal(SIGINT,stopWatchdog); signal(SIGCHLD,SIG_IGN);
    stopping=0;
    NSString* executable=processIdentity(getpid())[@"executable"];
    struct stat original={};
    if (!executable || stat(executable.fileSystemRepresentation,&original)) { logWatchdog(@"startup failed: executable identity unavailable"); return 1; }
    CLWatchdogRecovery* recovery=[CLWatchdogRecovery new];
    NSMutableDictionary* state=[@{@"status":@"running",@"instance":NSUUID.UUID.UUIDString,@"pid":@(getpid()),@"started_at":@(NSDate.date.timeIntervalSince1970),@"poll_interval_seconds":@10} mutableCopy];
    logWatchdog([NSString stringWithFormat:@"started pid=%@ instance=%@",state[@"pid"],state[@"instance"]]);
    if (!CLRoleIsLocked(@"service")) {
        int result=restart();
        logWatchdog([NSString stringWithFormat:@"initial service start requested result=%d (not a health confirmation)",result]);
    }
    BOOL checked=NO, lastHealthy=NO;
    NSString* exitReason=@"received signal";
    while (!stopping) {
        @autoreleasepool {
            struct stat current={};
            if (stat(executable.fileSystemRepresentation,&current) || current.st_dev!=original.st_dev || current.st_ino!=original.st_ino || current.st_mtimespec.tv_sec!=original.st_mtimespec.tv_sec || current.st_mtimespec.tv_nsec!=original.st_mtimespec.tv_nsec) { exitReason=@"app bundle removed or replaced"; break; }
            NSString* problem=nil;
            NSDictionary* owner=CLActiveRoleIdentity(@"service");
            BOOL healthy=CLProbeService(probeURL ?: [NSURL URLWithString:@"http://127.0.0.1:1230/"],owner,&problem)!=nil;
            if (!checked || healthy!=lastHealthy) logWatchdog(healthy ? @"service health confirmed" : [@"service unavailable or unresponsive: " stringByAppendingString:problem ?: @"unknown"]);
            checked=YES; lastHealthy=healthy;
            NSArray* actions=[recovery observeHealthy:healthy atUptime:NSProcessInfo.processInfo.systemUptime];
            for (NSString* action in actions) {
                if (stopping) break;
                if ([action isEqual:@"fallback"]) {
                    int result=restore();
                    // -3 means another service still owns control: retry later.
                    if (result!=-3) [recovery recordFallbackAttempt];
                    state[@"last_fallback_result"]=@(result);
                    state[@"last_fallback_at"]=@(NSDate.date.timeIntervalSince1970);
                    logWatchdog([NSString stringWithFormat:@"system-charging fallback result=%d (-3=service still active, 0=API accepted, -1/-2=API failed; actual charging requires a battery report)",result]);
                } else {
                    int result=restart();
                    state[@"last_restart_result"]=@(result);
                    logWatchdog([NSString stringWithFormat:@"recovery attempt=%@ spawn/start result=%d; waiting for health confirmation",recovery.state[@"restart_attempts"],result]);
                }
            }
            state[@"heartbeat_at"]=@(NSDate.date.timeIntervalSince1970);
            state[@"service_healthy"]=@(healthy);
            state[@"recovery"]=recovery.state;
            state[@"last_probe_error"]=healthy ? @"" : (problem ?: @"unknown");
            CLWriteWatchdogState(state,nil);
        }
        // Signals can interrupt sleep; do not wait for the next full tick to exit.
        for (int i=0;i<100 && !stopping;i++) usleep(100000);
    }
    state[@"status"]=@"stopped"; state[@"stopped_at"]=@(NSDate.date.timeIntervalSince1970); state[@"exit_reason"]=exitReason;
    CLWriteWatchdogState(state,nil); logWatchdog([@"stopped: " stringByAppendingString:exitReason]);
    (void)heldLease;
    return 0;
}
