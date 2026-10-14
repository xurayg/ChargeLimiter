#pragma once
#import <Foundation/Foundation.h>

@interface CLProcessLease : NSObject
@property(nonatomic, readonly, copy) NSDictionary* identity;
+ (instancetype)acquireRole:(NSString*)role;
@end
BOOL CLRoleIsLocked(NSString* role);
NSDictionary* CLActiveRoleIdentity(NSString* role);
// Checks the executable and process birth time, never kills by name or stale PID.
BOOL CLStopOwnedService(NSURL* probeURL = nil);
NSDictionary* CLProbeService(NSURL* url, NSDictionary* owner, NSString** error);

@interface CLWatchdogRecovery : NSObject
@property(nonatomic, readonly, copy) NSDictionary* state;
- (NSArray<NSString*>*)observeHealthy:(BOOL)healthy atUptime:(NSTimeInterval)time;
- (void)recordFallbackAttempt;
@end
// Runs in a separate process. Callbacks return spawn result / restore result.
int CLRunWatchdog(int (^restart)(void), int (^restore)(void), NSURL* probeURL = nil);
