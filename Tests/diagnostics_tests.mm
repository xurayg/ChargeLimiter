#import "diagnostics.h"
#import "storage.h"
#include <stdlib.h>
static void check(BOOL ok, NSString* message) { if (!ok) { NSLog(@"FAIL: %@",message); exit(1); } }
static BOOL contains(NSArray* lines, NSString* needle) {
    for (NSString* line in lines) if ([line containsString:needle]) return YES;
    return NO;
}
static NSDictionary* sample(BOOL charging, int current) {
    return @{@"IsCharging":@(charging), @"Amperage":@(current), @"CurrentCapacity":@59, @"Temperature":@2900, @"ExternalConnected":@YES, @"UpdateTime":@100};
}
int main() {
    @autoreleasepool {
        NSError* error = nil;
        check(CLInitializeStorage(&error), @"initialize");
        CLChargeDiagnostics* monitor = [CLChargeDiagnostics new];
        check(contains([monitor observeBattery:sample(NO,-100) atUptime:0],@"battery initial report"), @"baseline logged");
        check([[monitor observeBattery:sample(NO,-100) atUptime:1] count] == 0,@"unchanged state not repeated");
        check(contains([monitor recordRequest:YES result:-2 atUptime:2],@"API failed"), @"failure distinguished from acceptance");
        check([[monitor observeBattery:sample(NO,-100) atUptime:200] count] == 0,@"failed command does not create a false pending target");
        check(contains([monitor recordRequest:YES result:0 atUptime:210],@"waiting for a fresh battery report"),@"API return is not reported as charging confirmation");
        check([[monitor observeBattery:sample(NO,-100) atUptime:220] count] == 0,@"pending target waits");
        [monitor recordRequest:YES result:0 atUptime:320];
        check(contains([monitor observeBattery:sample(NO,-100) atUptime:330],@"NOT reported"),@"repeated request does not postpone timeout");
        check([[monitor observeBattery:sample(NO,-100) atUptime:340] count] == 0,@"timeout logged once");
        NSArray* changed=[monitor observeBattery:sample(YES,700) atUptime:350];
        check(contains(changed,@"IsCharging=0 -> 1"),@"observed charging transition logged");
        check(contains(changed,@"positive charging current reported"),@"current evidence recorded");
        check([[monitor observeBattery:sample(YES,700) atUptime:360] count] == 0,@"confirmed stable state not repeated");
        [monitor recordRequest:NO result:0 atUptime:370];
        check(contains([monitor observeBattery:sample(NO,0) atUptime:375],@"system reports charging stopped"),@"observed stop logged");
        [monitor recordRequest:YES result:0 atUptime:380];
        check(contains([monitor observeBattery:sample(YES,0) atUptime:385],@"no positive current"),@"matching flag without current is not physical verification");
        check(contains([monitor observeBattery:@{} atUptime:400],@"IsCharging missing"),@"missing field does not mean stopped");
        check([[monitor observeBattery:@{} atUptime:410] count] == 0,@"missing state warning deduplicated");
        [monitor recordRequest:NO result:0 atUptime:420];
        check(contains([monitor observeBattery:@{} atUptime:540],@"battery report unavailable"),@"missing reports also produce a 120s warning");
        NSDictionary* conf = @{@"enable":@YES, @"charge_below":@60, @"charge_above":@80, @"enable_temp":@YES, @"charge_temp_above":@35, @"temp_mode":@0, @"adv_disable_inflow":@NO};
        NSMutableDictionary* battery = [sample(NO,-100) mutableCopy];
        battery[@"ExternalChargeCapable"] = @YES;
        CLChargeDiagnostics* reasons = [CLChargeDiagnostics new];
        check([CLChargingExplanation(conf,battery,[reasons stateAtUptime:0],NO)[@"code"] isEqual:@"no_start_request"],@"eligible without a request does not invent a hardware cause");
        [reasons recordRequest:YES result:-1 atUptime:1];
        check([CLChargingExplanation(conf,battery,[reasons stateAtUptime:2],NO)[@"code"] isEqual:@"charge_failed"],@"failed start interface explained");
        [reasons recordRequest:YES result:0 atUptime:3];
        check([CLChargingExplanation(conf,battery,[reasons stateAtUptime:5],NO)[@"code"] isEqual:@"charge_pending"],@"accepted start is still waiting for report");
        [reasons recordRequest:YES result:0 atUptime:110];
        check([CLChargingExplanation(conf,battery,[reasons stateAtUptime:123],NO)[@"code"] isEqual:@"charge_timeout"],@"repeated start does not postpone explanation timeout");
        battery[@"Temperature"] = @3600;
        check([CLChargingExplanation(conf,battery,[reasons stateAtUptime:123],NO)[@"code"] isEqual:@"temperature_limit"],@"temperature blocker takes priority over command history");
        NSMutableDictionary* fahrenheit = conf.mutableCopy; fahrenheit[@"temp_mode"] = @1; fahrenheit[@"charge_temp_above"] = @95;
        check([CLChargingExplanation(fahrenheit,battery,@{},NO)[@"code"] isEqual:@"temperature_limit"],@"Fahrenheit protection threshold converted");
        battery[@"CurrentCapacity"] = @5;
        check([CLChargingExplanation(conf,battery,@{},NO)[@"code"] isEqual:@"no_start_request"],@"critical capacity overrides temperature protection like daemon policy");
        battery[@"CurrentCapacity"] = @59; battery[@"Temperature"] = @2900;
        NSMutableDictionary* overlap = conf.mutableCopy; overlap[@"charge_above"] = @50;
        check([CLChargingExplanation(overlap,battery,@{},NO)[@"code"] isEqual:@"capacity_limit"],@"upper limit wins if thresholds overlap");
        battery[@"ExternalChargeCapable"] = @NO;
        check([CLChargingExplanation(conf,battery,@{},NO)[@"code"] isEqual:@"no_adapter"],@"power source blocker explained");
        check([CLChargingExplanation(conf,battery,@{},YES)[@"code"] isEqual:@"no_start_request"],@"UPS overrides power flags like daemon");
        NSMutableDictionary* disableInflow = conf.mutableCopy; disableInflow[@"adv_disable_inflow"] = @YES;
        battery[@"AdapterDetails"] = @{@"Description":@"usb"}; battery[@"ExternalConnected"] = @NO;
        [reasons recordInflowRequest:YES result:-2 atUptime:124];
        check([CLChargingExplanation(disableInflow,battery,[reasons stateAtUptime:125],NO)[@"code"] isEqual:@"inflow_failed"],@"inflow restore failure distinguished from charge command");
        [reasons recordInflowRequest:YES result:0 atUptime:126];
        battery[@"ExternalChargeCapable"] = @YES; battery[@"ExternalConnected"] = @YES; battery[@"IsCharging"] = @YES; battery[@"Amperage"] = @0;
        [reasons observeBattery:battery atUptime:127];
        check([CLChargingExplanation(conf,battery,[reasons stateAtUptime:128],NO)[@"code"] isEqual:@"charging_no_current"],@"reported charging without current is explicit");
        battery[@"IsCharging"] = @NO;
        check([CLChargingExplanation(conf,battery,[reasons stateAtUptime:129],NO)[@"code"] isEqual:@"charging_lost"],@"previous confirmation is not treated as a new pending start");
        [reasons recordRequest:NO result:0 atUptime:130]; [reasons observeBattery:battery atUptime:131];
        check([CLChargingExplanation(conf,battery,[reasons stateAtUptime:132],NO)[@"code"] isEqual:@"last_stop"],@"latest stop request described without inventing its origin");
        [reasons recordRequest:NO result:-2 atUptime:133];
        check([CLChargingExplanation(conf,battery,[reasons stateAtUptime:134],NO)[@"code"] isEqual:@"unknown"],@"failed stop does not falsely claim no start has ever been recorded");
        [battery removeObjectForKey:@"IsCharging"];
        check([CLChargingExplanation(conf,battery,@{},NO)[@"code"] isEqual:@"missing_report"],@"missing charging state remains unknown");
        NSMutableDictionary* off = conf.mutableCopy; off[@"enable"] = @NO; battery[@"IsCharging"] = @NO;
        check([CLChargingExplanation(off,battery,@{},NO)[@"code"] isEqual:@"disabled"],@"automatic control disabled explained");
        CLServiceDiagnostics* service=[CLServiceDiagnostics new];
        check(contains([service startWithPID:101 systemBoot:10 atTime:1000],@"service started"),@"service startup");
        [service heartbeatAtTime:1005]; check([service save:&error],@"persist heartbeat");
        check([CLReadServiceState()[@"heartbeat_at"] intValue]==1005,@"heartbeat survives process restart");
        NSString* oldInstance=service.state[@"instance"];
        CLServiceDiagnostics* restarted=[CLServiceDiagnostics new];
        check(contains([restarted startWithPID:102 systemBoot:10 atTime:1030],@"possible crash/forced kill; exact cause unknown"),@"unclean restart detected without inventing cause");
        check(![oldInstance isEqual:restarted.state[@"instance"]],@"new service instance identifier");
        [restarted stopWithReason:@"received signal 15" atTime:1040];
        check([restarted save:&error],@"normal exit persisted");
        check([CLReadServiceState()[@"exit_reason"] isEqual:@"received signal 15"],@"exit reason available");
        CLServiceDiagnostics* clean=[CLServiceDiagnostics new];
        check(!contains([clean startWithPID:103 systemBoot:10 atTime:1045],@"clean exit"),@"normal restart not labelled crash");
        check([clean save:&error],@"new running state persisted");
        CLServiceDiagnostics* reboot=[CLServiceDiagnostics new];
        check(contains([reboot startWithPID:104 systemBoot:20 atTime:1100],@"system boot changed"),@"reboot distinguished from same-boot interruption");
        NSLog(@"PASS: charge reports, policy explanations, command/inflow failures, unknown causes, 120s timeout, duplicate suppression, current evidence, missing fields, heartbeats, clean/unclean/reboot lifecycle");
    }
    return 0;
}
