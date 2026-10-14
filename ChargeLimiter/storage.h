#pragma once
#import <Foundation/Foundation.h>

#ifndef CL_DATA_DIRECTORY
#define CL_DATA_DIRECTORY "/var/mobile/Library/ChargeLimiter"
#endif
#ifndef CL_LEGACY_DIRECTORY
#define CL_LEGACY_DIRECTORY "/var/root"
#endif

BOOL CLInitializeStorage(NSError** error);
NSDictionary* CLReadConfiguration(NSError** error);
BOOL CLWriteConfiguration(NSString* key, id value, NSError** error);
BOOL CLWriteConfigurationValues(NSDictionary* values, NSError** error);
BOOL CLAppendLog(NSString* line, NSError** error);
NSString* CLReadLogTail(NSUInteger maxBytes, NSError** error);
NSDictionary* CLCreateExport(NSDictionary* battery, NSError** error);
NSDictionary* CLStorageInfo(void);
NSDictionary* CLReadServiceState(void);
BOOL CLWriteServiceState(NSDictionary* state, NSError** error);
NSDictionary* CLReadWatchdogState(void);
BOOL CLWriteWatchdogState(NSDictionary* state, NSError** error);
