#import "watchdog.h"
#import "storage.h"
#include <stdio.h>
#include <unistd.h>
#include <spawn.h>
#include <errno.h>
extern char** environ;
static void check(BOOL ok, NSString* message) { if (!ok) { NSLog(@"FAIL: %@",message); exit(1); } }
static void printJSON(id value) { NSData* d=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil]; fwrite(d.bytes,1,d.length,stdout); puts(""); fflush(stdout); }
int main(int argc,char** argv) {
    @autoreleasepool {
        check(CLInitializeStorage(nil),@"storage");
        NSString* mode=argc>1 ? @(argv[1]) : @"test";
        if ([mode isEqual:@"lease"]) {
            signal(SIGTERM,SIG_IGN); // Match the TrollStore daemon's disposition.
            CLProcessLease* lease __attribute__((objc_precise_lifetime))=[CLProcessLease acquireRole:@"service"];
            if (!lease) return 10;
            printJSON(lease.identity);
            while (YES) sleep(1);
        }
        if ([mode isEqual:@"identity"]) { printJSON(CLActiveRoleIdentity(@"service") ?: @{}); return 0; }
        if ([mode isEqual:@"stop"]) { BOOL stopped=CLStopOwnedService(argc>2 ? [NSURL URLWithString:@(argv[2])] : nil); printJSON(@{@"stopped":@(stopped)}); return 0; }
        if ([mode isEqual:@"engine"] || [mode isEqual:@"engine_fail"]) {
            BOOL failRestarts=[mode isEqual:@"engine_fail"];
            NSURL* url=[NSURL URLWithString:@(argv[2])];
            NSString* executable=[@(argv[0]) stringByDeletingLastPathComponent];
            executable=[executable stringByAppendingPathComponent:@"ChargeLimiterDaemon"];
            return CLRunWatchdog(^int {
                if (failRestarts) return EAGAIN;
                CLStopOwnedService(url);
                if (CLRoleIsLocked(@"service")) return -3;
                pid_t child=0; char* args[]={(char*)executable.fileSystemRepresentation,(char*)"lease",NULL};
                return posix_spawn(&child,args[0],NULL,NULL,args,environ);
            },^int {
                CLProcessLease* guard __attribute__((objc_precise_lifetime))=[CLProcessLease acquireRole:@"service"];
                if (!guard) return -3;
                CLAppendLog(@"test fallback invoked\n",nil);
                return 0;
            },url);
        }
        if ([mode isEqual:@"probe"]) {
            NSDictionary* owner=CLActiveRoleIdentity(@"service");
            NSString* error=nil;
            NSDictionary* response=CLProbeService([NSURL URLWithString:@(argv[2])],owner,&error);
            printJSON(@{@"healthy":@(response!=nil),@"error":error ?: @""}); return 0;
        }
        CLWatchdogRecovery* recovery=[CLWatchdogRecovery new];
        check([[recovery observeHealthy:NO atUptime:0] count]==0,@"one failure does not restart");
        check([[recovery observeHealthy:NO atUptime:10] count]==0,@"two failures do not restart");
        check([[recovery observeHealthy:NO atUptime:20] isEqual:@[@"restart"]],@"third failure restarts");
        check([[recovery observeHealthy:NO atUptime:25] count]==0,@"retry is throttled");
        check([[recovery observeHealthy:NO atUptime:30] isEqual:@[@"restart"]],@"second attempt after backoff");
        check([[recovery observeHealthy:NO atUptime:49] count]==0,@"second backoff");
        check([[recovery observeHealthy:NO atUptime:50] isEqual:@[@"restart"]],@"third attempt");
        check([[recovery observeHealthy:NO atUptime:89] count]==0,@"third restart given time to recover");
        check([[recovery observeHealthy:NO atUptime:90] isEqual:@[@"fallback",@"restart"]],@"continued failure invokes fallback then retry");
        [recovery recordFallbackAttempt];
        check([[recovery observeHealthy:NO atUptime:120] count]==0,@"long backoff prevents recovery storm");
        check([[recovery observeHealthy:NO atUptime:210] isEqual:@[@"restart"]],@"fallback not repeatedly written");
        [recovery observeHealthy:YES atUptime:220]; [recovery observeHealthy:YES atUptime:240];
        check([recovery.state[@"restart_attempts"] intValue]==5,@"brief success does not reset crash-loop budget");
        [recovery observeHealthy:YES atUptime:250];
        check([recovery.state[@"restart_attempts"] intValue]==0,@"stable 30s recovery resets budget");
        check(![recovery.state[@"fallback_attempted"] boolValue],@"next incident may fall back again");
        [recovery observeHealthy:NO atUptime:260]; [recovery observeHealthy:YES atUptime:270];
        check([recovery.state[@"consecutive_failures"] intValue]==0,@"transient failure cleared on health confirmation");
        CLWatchdogRecovery* busy=[CLWatchdogRecovery new];
        for (NSNumber* t in @[@0,@10,@20,@30,@50]) [busy observeHealthy:NO atUptime:t.doubleValue];
        [busy observeHealthy:NO atUptime:90];
        check([[busy observeHealthy:NO atUptime:210] containsObject:@"fallback"],@"busy lease leaves fallback eligible for later retry");
        check(CLWriteWatchdogState(@{@"status":@"running",@"pid":@42},nil),@"watchdog state persists");
        check([CLReadWatchdogState()[@"pid"] intValue]==42,@"watchdog state readable for offline export");
        NSLog(@"PASS: independent recovery state machine, failure threshold, backoff, fallback deduplication, stable recovery and persistence");
    }
    return 0;
}
