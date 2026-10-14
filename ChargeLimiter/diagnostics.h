#pragma once
#import <Foundation/Foundation.h>

// Observes fresh registry samples. Matching IsCharging is a system report,
// not proof that the battery has physically accepted current.
@interface CLChargeDiagnostics : NSObject
- (NSArray<NSString*>*)recordRequest:(BOOL)target result:(int)result atUptime:(NSTimeInterval)uptime;
- (NSArray<NSString*>*)observeBattery:(NSDictionary*)battery atUptime:(NSTimeInterval)uptime;
- (void)recordInflowRequest:(BOOL)target result:(int)result atUptime:(NSTimeInterval)uptime;
- (NSDictionary*)stateAtUptime:(NSTimeInterval)uptime;
@end

// Explanations describe observable policy/command evidence, never infer hardware faults.
NSDictionary* CLChargingExplanation(NSDictionary* config, NSDictionary* battery, NSDictionary* commands, BOOL hasUPS);

@interface CLServiceDiagnostics : NSObject
@property(nonatomic, readonly, copy) NSDictionary* state;
- (NSArray<NSString*>*)startWithPID:(int)pid systemBoot:(int)boot atTime:(NSTimeInterval)time;
- (void)heartbeatAtTime:(NSTimeInterval)time;
- (void)stopWithReason:(NSString*)reason atTime:(NSTimeInterval)time;
- (BOOL)save:(NSError**)error;
@end
