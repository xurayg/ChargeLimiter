#include "storage.h"
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <pwd.h>
#include <errno.h>

static NSString* CLPath(NSString* name) {
    return [@CL_DATA_DIRECTORY stringByAppendingPathComponent:name];
}
static BOOL CLPosixError(NSError** error) {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    return NO;
}
static void CLSetPermissions(NSString* path, BOOL directory) {
    struct passwd* mobile = getpwnam("mobile");
    if (mobile && geteuid() == 0) chown(path.fileSystemRepresentation, mobile->pw_uid, mobile->pw_gid);
    chmod(path.fileSystemRepresentation, directory ? 0700 : 0640);
}
static BOOL CLDirectory(NSString* path, NSError** error) {
    if (![[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    CLSetPermissions(path, YES);
    return YES;
}
BOOL CLInitializeStorage(NSError** error) {
    if (!CLDirectory(@CL_DATA_DIRECTORY, error)) return NO;
    // Serialize first-launch migration across the UI, HUD and daemon processes.
    int fd = open(CLPath(@"storage.lock").fileSystemRepresentation, O_CREAT | O_RDWR, 0640);
    if (fd < 0) return CLPosixError(error);
    CLSetPermissions(CLPath(@"storage.lock"), NO);
    if (flock(fd, LOCK_EX) != 0) { close(fd); return CLPosixError(error); }
    BOOL success = YES;
    NSFileManager* fm = NSFileManager.defaultManager;
    for (NSString* name in @[@"aldente.conf", @"aldente.log", @"aldente.db"]) {
        NSString* old = [@CL_LEGACY_DIRECTORY stringByAppendingPathComponent:name];
        NSString* path = CLPath(name);
        if (![fm fileExistsAtPath:path] && [fm fileExistsAtPath:old]) {
            // Stage and rename so an interrupted copy never becomes the active file.
            NSString* staging = CLPath([@"migration-" stringByAppendingString:NSUUID.UUID.UUIDString]);
            if (![fm copyItemAtPath:old toPath:staging error:error] || ![fm moveItemAtPath:staging toPath:path error:error]) {
                success = NO;
                break;
            }
        }
        if ([fm fileExistsAtPath:path]) CLSetPermissions(path, NO);
    }
    if (success) success = CLDirectory(CLPath(@"ConfigHistory"), error) && CLDirectory(CLPath(@"Exports"), error);
    flock(fd, LOCK_UN);
    close(fd);
    return success;
}
NSDictionary* CLReadConfiguration(NSError** error) {
    NSString* path = CLPath(@"aldente.conf");
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return @{};
    NSData* data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return nil;
    id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:error];
    if (![value isKindOfClass:NSDictionary.class]) {
        if (error && !*error) *error = [NSError errorWithDomain:@"ChargeLimiter.Storage" code:1 userInfo:@{NSLocalizedDescriptionKey:@"配置文件损坏，已保留原文件，未用默认值覆盖。"}];
        return nil;
    }
    return value;
}
static NSString* CLUniqueName() {
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss-SSS";
    return [NSString stringWithFormat:@"%@-%@", [formatter stringFromDate:NSDate.date], NSUUID.UUID.UUIDString];
}
BOOL CLWriteConfiguration(NSString* key, id value, NSError** error) {
    return CLWriteConfigurationValues(@{key:value}, error);
}
BOOL CLWriteConfigurationValues(NSDictionary* values, NSError** error) {
    int fd = open(CLPath(@"storage.lock").fileSystemRepresentation, O_RDWR);
    if (fd < 0) return CLPosixError(error);
    if (flock(fd, LOCK_EX) != 0) { close(fd); return CLPosixError(error); }
    NSDictionary* existing = CLReadConfiguration(error);
    BOOL success = existing != nil;
    NSMutableDictionary* updated = existing.mutableCopy;
    [updated addEntriesFromDictionary:values];
    if (success && ![existing isEqual:updated]) {
        NSData* data = [NSPropertyListSerialization dataWithPropertyList:updated format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
        NSString* history = CLPath([NSString stringWithFormat:@"ConfigHistory/%@.plist", CLUniqueName()]);
        // Every saved revision has a unique name. The active configuration is replaced only on an explicit change.
        success = data && [data writeToFile:history options:NSDataWritingWithoutOverwriting error:error];
        if (success) {
            CLSetPermissions(history, NO);
            success = [data writeToFile:CLPath(@"aldente.conf") options:NSDataWritingAtomic error:error];
            if (success) CLSetPermissions(CLPath(@"aldente.conf"), NO);
        }
    }
    flock(fd, LOCK_UN);
    close(fd);
    return success;
}
BOOL CLAppendLog(NSString* line, NSError** error) {
    int fd = open(CLPath(@"aldente.log").fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0640);
    if (fd < 0) return CLPosixError(error);
    CLSetPermissions(CLPath(@"aldente.log"), NO);
    if (flock(fd, LOCK_EX) != 0) { close(fd); return CLPosixError(error); }
    NSData* data = [line dataUsingEncoding:NSUTF8StringEncoding];
    const char* bytes = (const char*)data.bytes;
    NSUInteger left = data.length;
    BOOL success = YES;
    while (left) {
        ssize_t n = write(fd, bytes, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { success = CLPosixError(error); break; }
        bytes += n;
        left -= n;
    }
    flock(fd, LOCK_UN);
    close(fd);
    return success;
}
NSString* CLReadLogTail(NSUInteger maxBytes, NSError** error) {
    NSString* path = CLPath(@"aldente.log");
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return @"暂无日志";
    NSFileHandle* file = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!file) { CLPosixError(error); return nil; }
    if (flock(file.fileDescriptor, LOCK_SH) != 0) { [file closeFile]; CLPosixError(error); return nil; }
    unsigned long long size = [file seekToEndOfFile];
    [file seekToFileOffset:size > maxBytes ? size - maxBytes : 0];
    NSData* data = [file readDataToEndOfFile];
    flock(file.fileDescriptor, LOCK_UN);
    [file closeFile];
    if (size > maxBytes) {
        // Drop a partial line, including any partial UTF-8 character.
        const char* bytes = (const char*)data.bytes;
        for (NSUInteger i = 0; i < data.length; i++) if (bytes[i] == '\n') {
            data = [data subdataWithRange:NSMakeRange(i + 1, data.length - i - 1)];
            break;
        }
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"日志包含无法显示的字符，请导出完整日志。";
}
NSDictionary* CLCreateExport(NSDictionary* battery, NSError** error) {
    NSDictionary* config = CLReadConfiguration(error);
    if (!config) return nil;
    NSString* name = CLUniqueName();
    NSString* directory = CLPath([@"Exports" stringByAppendingPathComponent:name]);
    if (!CLDirectory(directory, error)) return nil;
    NSData* plist = [NSPropertyListSerialization dataWithPropertyList:config format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    NSData* json = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:error];
    NSData* state = [NSJSONSerialization dataWithJSONObject:@{@"exported_at": [[NSISO8601DateFormatter new] stringFromDate:NSDate.date], @"battery": battery ?: @{}, @"service":CLReadServiceState(), @"storage_directory": @CL_DATA_DIRECTORY} options:NSJSONWritingPrettyPrinted error:error];
    if (!plist || !json || !state) return nil;
    NSDictionary* payload = @{@"configuration.plist":plist, @"configuration.json":json, @"battery.json":state};
    for (NSString* fileName in payload) {
        NSString* path = [directory stringByAppendingPathComponent:fileName];
        if (![payload[fileName] writeToFile:path options:NSDataWritingWithoutOverwriting error:error]) return nil;
        CLSetPermissions(path, NO);
    }
    NSString* logPath = CLPath(@"aldente.log");
    NSString* logCopy = [directory stringByAppendingPathComponent:@"aldente.log"];
    int fd = open(logPath.fileSystemRepresentation, O_RDONLY);
    BOOL copied = NO;
    if (fd >= 0) {
        if (flock(fd, LOCK_SH) == 0) {
            copied = [NSFileManager.defaultManager copyItemAtPath:logPath toPath:logCopy error:error];
            flock(fd, LOCK_UN);
        } else CLPosixError(error);
        close(fd);
    } else if (errno == ENOENT) copied = [NSData.data writeToFile:logCopy options:NSDataWritingWithoutOverwriting error:error];
    else CLPosixError(error);
    if (!copied) return nil;
    CLSetPermissions(logCopy, NO);
    return @{@"directory":directory, @"download_prefix":[NSString stringWithFormat:@"/exports/%@/", name], @"files":@[@"aldente.log", @"configuration.json", @"configuration.plist", @"battery.json"]};
}
NSDictionary* CLStorageInfo(void) {
    NSArray* names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:CLPath(@"Exports") error:nil];
    NSMutableArray* exports = [NSMutableArray new];
    NSArray* files = @[@"aldente.log", @"configuration.json", @"configuration.plist", @"battery.json"];
    for (NSString* name in [[names sortedArrayUsingSelector:@selector(compare:)] reverseObjectEnumerator]) {
        NSString* directory = CLPath([@"Exports" stringByAppendingPathComponent:name]);
        BOOL complete = YES;
        for (NSString* file in files) if (![NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:file]]) complete = NO;
        if (!complete) continue;
        [exports addObject:@{@"name":name, @"directory":directory, @"download_prefix":[NSString stringWithFormat:@"/exports/%@/", name], @"files":files}];
    }
    NSArray* revisions = [NSFileManager.defaultManager contentsOfDirectoryAtPath:CLPath(@"ConfigHistory") error:nil];
    return @{@"directory":@CL_DATA_DIRECTORY, @"configuration_revisions":@(revisions.count), @"exports":exports, @"service":CLReadServiceState()};
}
NSDictionary* CLReadServiceState(void) {
    NSData* data = [NSData dataWithContentsOfFile:CLPath(@"service-state.json")];
    id state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [state isKindOfClass:NSDictionary.class] ? state : @{};
}
BOOL CLWriteServiceState(NSDictionary* state, NSError** error) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:error];
    NSString* path = CLPath(@"service-state.json");
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    CLSetPermissions(path, NO);
    return YES;
}
