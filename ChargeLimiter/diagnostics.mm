#include "diagnostics.h"
#include "storage.h"

@implementation CLChargeDiagnostics {
    NSNumber* lastCharging;
    NSNumber* pendingTarget;
    NSTimeInterval pendingSince;
    BOOL timeoutLogged;
    BOOL missingStateLogged;
    NSMutableDictionary* requestState;
    NSDictionary* inflowState;
}
- (NSArray<NSString*>*)recordRequest:(BOOL)target result:(int)result atUptime:(NSTimeInterval)uptime {
    NSMutableArray* lines = [NSMutableArray new];
    [lines addObject:[NSString stringWithFormat:@"charge command target=%d result=%d (%@)", target, result, result == 0 ? @"API accepted; waiting for a fresh battery report" : @"API failed; charging state not confirmed"]];
    requestState = [@{@"target":@(target), @"result":@(result), @"uptime":@(uptime), @"confirmed":@NO} mutableCopy];
    if (result == 0) {
        // Repeated commands must not indefinitely postpone the 120-second warning.
        if (!pendingTarget || pendingTarget.boolValue != target) {
            pendingTarget = @(target);
            pendingSince = uptime;
            timeoutLogged = NO;
        }
    }
    return lines;
}
- (NSArray<NSString*>*)observeBattery:(NSDictionary*)battery atUptime:(NSTimeInterval)uptime {
    NSMutableArray* lines = [NSMutableArray new];
    NSNumber* reported = battery[@"IsCharging"];
    if (!reported) {
        if (!missingStateLogged) [lines addObject:@"battery state unavailable: IsCharging missing; cannot confirm charging"];
        missingStateLogged = YES;
        if (pendingTarget && uptime - pendingSince >= 120 && !timeoutLogged) {
            [lines addObject:[NSString stringWithFormat:@"charge target NOT verified after %.1fs: target=%d; battery report unavailable", uptime - pendingSince, pendingTarget.boolValue]];
            timeoutLogged = YES;
        }
        return lines;
    }
    missingStateLogged = NO;
    NSString* sample = [NSString stringWithFormat:@"IsCharging=%d capacity=%@%% amperage=%@mA temperature=%.2fC ExternalConnected=%@ batteryUpdateTime=%@", reported.boolValue, battery[@"CurrentCapacity"] ?: @"unknown", battery[@"Amperage"] ?: @"unknown", [battery[@"Temperature"] doubleValue] / 100, battery[@"ExternalConnected"] ?: @"unknown", battery[@"UpdateTime"] ?: @"unknown"];
    if (!lastCharging) [lines addObject:[@"battery initial report " stringByAppendingString:sample]];
    else if (lastCharging.boolValue != reported.boolValue) [lines addObject:[NSString stringWithFormat:@"battery state changed IsCharging=%d -> %d; %@", lastCharging.boolValue, reported.boolValue, sample]];
    lastCharging = @(reported.boolValue);
    if (pendingTarget) {
        NSTimeInterval elapsed = MAX(0, uptime - pendingSince);
        if (reported.boolValue == pendingTarget.boolValue) {
            NSString* evidence = reported.boolValue ? ([battery[@"Amperage"] longLongValue] > 0 ? @"positive charging current reported" : @"no positive current in this sample; check current/capacity trend") : @"system reports charging stopped";
            [lines addObject:[NSString stringWithFormat:@"charge target reported after %.1fs: %@; %@ (system-reported, not hardware verification)", elapsed, sample, evidence]];
            pendingTarget = nil;
            if ([requestState[@"result"] intValue] == 0 && [requestState[@"target"] boolValue] == reported.boolValue) requestState[@"confirmed"] = @YES;
        } else if (elapsed >= 120 && !timeoutLogged) {
            [lines addObject:[NSString stringWithFormat:@"charge target NOT reported after %.1fs: target=%d; %@", elapsed, pendingTarget.boolValue, sample]];
            timeoutLogged = YES;
        }
    }
    return lines;
}
- (void)recordInflowRequest:(BOOL)target result:(int)result atUptime:(NSTimeInterval)uptime {
    inflowState = @{@"target":@(target), @"result":@(result), @"uptime":@(uptime)};
}
- (NSDictionary*)stateAtUptime:(NSTimeInterval)uptime {
    NSMutableDictionary* state = [NSMutableDictionary new];
    if (requestState) {
        NSMutableDictionary* request = requestState.mutableCopy;
        request[@"age_seconds"] = @(MAX(0, uptime - [request[@"uptime"] doubleValue]));
        state[@"charge_request"] = request;
    }
    if (inflowState) state[@"inflow_request"] = inflowState;
    if (pendingTarget) {
        state[@"pending_target"] = pendingTarget;
        state[@"pending_seconds"] = @(MAX(0, uptime - pendingSince));
    }
    return state;
}
@end

static NSDictionary* explanation(NSString* code, NSString* zh, NSString* en, NSString* detailZH, NSString* detailEN) {
    return @{@"code":code, @"title_zh":zh, @"title_en":en, @"detail_zh":detailZH, @"detail_en":detailEN};
}
NSDictionary* CLChargingExplanation(NSDictionary* config, NSDictionary* battery, NSDictionary* commands, BOOL hasUPS) {
    if (!battery[@"CurrentCapacity"] || !battery[@"IsCharging"])
        return explanation(@"missing_report", @"电池状态不完整", @"Battery report incomplete", @"未读到电量或充电状态，无法判断是否满足条件。", @"Capacity or charging status is missing; eligibility cannot be determined.");
    if (![config[@"enable"] boolValue])
        return explanation(@"disabled", @"自动控制未启用", @"Automatic control is off", @"最低电量设置只有启用自动控制后才生效。", @"Enable automatic control to apply the capacity thresholds.");
    NSInteger capacity = [battery[@"CurrentCapacity"] integerValue];
    BOOL critical = capacity <= 5;
    if (!config[@"charge_below"] || !config[@"charge_above"])
        return explanation(@"missing_config", @"充电阈值不完整", @"Charging thresholds missing", @"请检查上下限设置。", @"Check the lower and upper capacity thresholds.");
    if (!critical && capacity >= [config[@"charge_above"] integerValue])
        return explanation(@"capacity_limit", @"电量上限阻止充电", @"Capacity limit blocks charging", [NSString stringWithFormat:@"当前电量 %ld%% ≥ 上限 %@%%；停充条件优先于开始充电条件。", (long)capacity, config[@"charge_above"]], @"The capacity is at or above the upper threshold. Stop conditions take priority.");
    double upper = [config[@"charge_temp_above"] doubleValue];
    if ([config[@"temp_mode"] intValue] == 1) upper = (upper - 32) / 1.8;
    if (!critical && [config[@"enable_temp"] boolValue]) {
        if (!battery[@"Temperature"] || !config[@"charge_temp_above"])
            return explanation(@"missing_temperature", @"温度状态未知", @"Temperature status unknown", @"温度保护已启用，但缺少温度或上限数据，无法确定是否被温度保护阻止。", @"Temperature protection is enabled, but its reading or threshold is missing.");
        if ([battery[@"Temperature"] doubleValue] / 100 >= upper)
            return explanation(@"temperature_limit", @"温度保护阻止充电", @"Temperature protection blocks charging", [NSString stringWithFormat:@"当前 %.1f°C ≥ 上限 %.1f°C；即使电量达到下限也会暂停充电。", [battery[@"Temperature"] doubleValue] / 100, upper], @"The temperature is at or above its limit, which takes priority over the lower capacity threshold.");
    }
    BOOL adaptor = [battery[@"ExternalChargeCapable"] boolValue];
    NSString* source = battery[@"AdapterDetails"][@"Description"];
    if ([config[@"adv_disable_inflow"] boolValue]) adaptor = source && ![source isEqualToString:@"batt"];
    if (hasUPS) adaptor = YES;
    if (!adaptor)
        return explanation(@"no_adapter", @"未识别到可充电电源", @"No charge-capable power source detected", [NSString stringWithFormat:@"电源可充电=%@，外部供电=%@，电源描述=%@。%@请检查充电器和连接；这些信息不能直接证明线缆或电池故障。", battery[@"ExternalChargeCapable"] ?: @"未知", battery[@"ExternalConnected"] ?: @"未知", source ?: @"无", [config[@"adv_disable_inflow"] boolValue] ? @"禁流模式依赖电源描述，该信息可能被系统缓存。" : @""], @"Check the charger and connection. Power-source flags alone cannot identify a cable or battery fault; adapter descriptions can be cached in inflow-disable mode.");
    if ([battery[@"IsCharging"] boolValue]) {
        BOOL positive = [battery[@"Amperage"] longLongValue] > 0;
        return explanation(positive ? @"charging" : @"charging_no_current", positive ? @"系统报告正在充电" : @"系统报告充电，但未读到正向电流", positive ? @"System reports charging" : @"Charging reported without positive current", [NSString stringWithFormat:@"IsCharging=1，电流=%@ mA。%@", battery[@"Amperage"] ?: @"未知", positive ? @"可结合后续电量上升确认实际充电。" : @"请观察后续电流和电量变化；具体原因暂未确定。"], @"IsCharging is a system report. Check subsequent current and capacity readings to assess actual charging.");
    }
    BOOL eligible = critical || capacity <= [config[@"charge_below"] integerValue];
    if (!eligible)
        return explanation(@"waiting_trigger", @"等待充电触发条件", @"Waiting for a charging trigger", @"当前电量高于下限；边缘模式等待电量降至下限，插电即充模式也可由新的插电事件触发。", @"Capacity is above the lower threshold. Edge mode waits for it; plug-and-charge mode can also start on a new connection event.");
    NSDictionary* inflow = commands[@"inflow_request"];
    if ([inflow[@"target"] boolValue] && [inflow[@"result"] intValue] != 0 && ![battery[@"ExternalConnected"] boolValue])
        return explanation(@"inflow_failed", @"恢复外部供电指令失败", @"Restoring external power failed", [NSString stringWithFormat:@"最近恢复供电指令返回 %@（-1：未找到电池控制接口；-2：系统驱动写入失败），当前仍未报告外部供电。请导出日志查看详细记录。", inflow[@"result"]], @"The latest power-restoration request failed and external power is still not reported. Export logs for details.");
    NSDictionary* request = commands[@"charge_request"];
    NSString* ageZH = [NSString stringWithFormat:@"最近指令距今 %.0f 秒。", [request[@"age_seconds"] doubleValue]];
    if ([request[@"target"] boolValue] && [request[@"result"] intValue] != 0)
        return explanation(@"charge_failed", @"开始充电指令失败", @"Start-charging request failed", [NSString stringWithFormat:@"%@返回 %@（-1：未找到电池控制接口；-2：系统驱动写入失败）。电量满足条件，但指令没有成功执行；请查看日志。", ageZH, request[@"result"]], @"The latest start request failed: -1 means the battery-control interface was not found; -2 means a driver property write failed. See logs for details.");
    if ([commands[@"pending_target"] boolValue]) {
        double elapsed = [commands[@"pending_seconds"] doubleValue];
        BOOL timedOut = elapsed >= 120;
        return explanation(timedOut ? @"charge_timeout" : @"charge_pending", timedOut ? @"指令已接受，仍未报告充电" : @"指令已接受，等待充电状态更新", timedOut ? @"Request accepted; charging still not reported" : @"Request accepted; waiting for charging report", [NSString stringWithFormat:@"开始充电接口返回成功，已等待 %.0f 秒，当前 IsCharging=0。%@", elapsed, timedOut ? @"系统未提供进一步原因，暂不能确定是系统限制还是硬件问题；请导出日志排查。" : @"接口成功不代表已经实际充电。"], timedOut ? @"The start API succeeded, but IsCharging remains false after 120 seconds. The exact system or hardware cause is unknown; export logs." : @"The start API succeeded, but IsCharging is still false. API acceptance does not confirm physical charging.");
    }
    if (request && ![request[@"target"] boolValue] && [request[@"result"] intValue] == 0)
        return explanation(@"last_stop", @"最近执行了停止充电指令", @"Latest request was to stop charging", [ageZH stringByAppendingString:@"当前电量满足开始条件，等待新的电池事件重新评估；手动操作也会影响当前状态。"], @"The latest successful request stopped charging. A new battery event will re-evaluate automatic control; manual changes also affect state.");
    if ([request[@"confirmed"] boolValue])
        return explanation(@"charging_lost", @"系统已不再报告充电", @"System no longer reports charging", [ageZH stringByAppendingString:@"此前开始指令已得到充电状态回应，当前变为未充电；具体原因未确定，等待电池事件重新评估。"], @"A previous start was reported as charging; the current report is stopped. The cause is unknown; a battery event will re-evaluate control.");
    if (request)
        return explanation(@"unknown", @"条件满足，未充电原因尚未确定", @"Eligible; cause not yet determined", [NSString stringWithFormat:@"%@最近指令目标=%@、结果=%@；当前系统仍报告未充电。请查看日志和后续电池状态。", ageZH, request[@"target"], request[@"result"]], @"Current conditions are eligible, but the available command and battery reports do not establish the cause. Check logs and subsequent reports.");
    return explanation(@"no_start_request", @"条件满足，尚未记录开始充电指令", @"Eligible; no start request recorded", @"本次服务运行尚未记录到开始指令。自动控制由电池事件触发；修改设置或刷新页面不会直接执行充电。可查看日志，或手动开启充电观察指令结果。", @"No start request has been recorded in this service instance. Battery events trigger control; changing settings or refreshing does not execute it. Check logs or try the manual charging switch.");
}

@implementation CLServiceDiagnostics {
    NSMutableDictionary* current;
}
- (NSDictionary*)state { return current.copy ?: @{}; }
- (NSArray<NSString*>*)startWithPID:(int)pid systemBoot:(int)boot atTime:(NSTimeInterval)time {
    NSMutableArray* lines = [NSMutableArray new];
    NSDictionary* previous = CLReadServiceState();
    if ([previous[@"status"] isEqualToString:@"running"]) {
        BOOL rebooted = [previous[@"system_boot"] intValue] != boot;
        [lines addObject:[NSString stringWithFormat:@"previous service did not record a clean exit: pid=%@ lastHeartbeat=%.0f gap=%.1fs; %@", previous[@"pid"], [previous[@"heartbeat_at"] doubleValue], MAX(0, time - [previous[@"heartbeat_at"] doubleValue]), rebooted ? @"system boot changed (reboot)" : @"possible crash/forced kill; exact cause unknown"]];
    }
    current = [@{@"status":@"running", @"instance":NSUUID.UUID.UUIDString, @"pid":@(pid), @"system_boot":@(boot), @"started_at":@(time), @"heartbeat_at":@(time)} mutableCopy];
    [lines addObject:[NSString stringWithFormat:@"service started pid=%d instance=%@", pid, current[@"instance"]]];
    return lines;
}
- (void)heartbeatAtTime:(NSTimeInterval)time { current[@"heartbeat_at"] = @(time); }
- (void)stopWithReason:(NSString*)reason atTime:(NSTimeInterval)time {
    current[@"status"] = @"stopped";
    current[@"stopped_at"] = @(time);
    current[@"exit_reason"] = reason ?: @"unknown";
}
- (BOOL)save:(NSError**)error { return CLWriteServiceState(self.state, error); }
@end
