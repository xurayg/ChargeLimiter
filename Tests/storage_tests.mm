#import "storage.h"
#include <sys/wait.h>
#include <unistd.h>
#include <stdlib.h>

static void check(BOOL condition, NSString* message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}
static NSData* bytes(NSString* path) { return [NSData dataWithContentsOfFile:path]; }
int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc == 2) {
            for (int i = 0; i < 30; i++) {
                if (!CLWriteConfiguration(@"child", @(i), nil) || !CLAppendLog(@"child完整行\n", nil)) return 2;
            }
            return 0;
        }
        NSFileManager* fm = NSFileManager.defaultManager;
        NSString* root = @CL_DATA_DIRECTORY;
        NSString* legacy = @CL_LEGACY_DIRECTORY;
        [fm createDirectoryAtPath:legacy withIntermediateDirectories:YES attributes:nil error:nil];
        [@{@"mode":@"edge_trigger", @"enable":@YES, @"charge_below":@60, @"charge_above":@80} writeToFile:[legacy stringByAppendingPathComponent:@"aldente.conf"] atomically:YES];
        [@"old log\n" writeToFile:[legacy stringByAppendingPathComponent:@"aldente.log"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"database marker" writeToFile:[legacy stringByAppendingPathComponent:@"aldente.db"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSError* error = nil;
        check(CLInitializeStorage(&error), [NSString stringWithFormat:@"migration: %@", error]);
        for (NSString* name in @[@"aldente.conf", @"aldente.log", @"aldente.db"]) check([bytes([root stringByAppendingPathComponent:name]) isEqual:bytes([legacy stringByAppendingPathComponent:name])], @"legacy bytes preserved");
        check([CLReadConfiguration(&error)[@"charge_below"] intValue] == 60, @"migrated threshold");
        check(CLWriteConfiguration(@"charge_below", @55, &error), @"save configuration");
        check([CLStorageInfo()[@"configuration_revisions"] intValue] == 1, @"one unique revision");
        check(CLWriteConfiguration(@"charge_below", @55, &error), @"unchanged configuration succeeds");
        check([CLStorageInfo()[@"configuration_revisions"] intValue] == 1, @"unchanged configuration does not rewrite");
        check(CLReadControlState().count == 0, @"missing control state reads empty");
        check(CLWriteControlState(@{@"charge":@NO, @"inflow":@NO}, &error), @"save control state");
        check([CLReadControlState()[@"inflow"] isEqual:@NO], @"control state persists");
        check(CLWriteControlState(@{}, &error) && CLReadControlState().count == 0, @"control state cleared");
        check(CLAppendLog(@"new log 中文\n", &error), @"append log");
        NSString* log = CLReadLogTail(1024, &error);
        check([log isEqualToString:@"old log\nnew log 中文\n"], @"append retains old log");
        NSData* savedConfig = bytes([root stringByAppendingPathComponent:@"aldente.conf"]);
        NSData* savedLog = bytes([root stringByAppendingPathComponent:@"aldente.log"]);
        NSDictionary* attrs = [fm attributesOfItemAtPath:[root stringByAppendingPathComponent:@"aldente.conf"] error:nil];
        check(CLInitializeStorage(&error), @"restart initialization");
        check([savedConfig isEqual:bytes([root stringByAppendingPathComponent:@"aldente.conf"])], @"restart retains config bytes");
        check([savedLog isEqual:bytes([root stringByAppendingPathComponent:@"aldente.log"])], @"restart retains log bytes");
        check([attrs[NSFileModificationDate] isEqual:[fm attributesOfItemAtPath:[root stringByAppendingPathComponent:@"aldente.conf"] error:nil][NSFileModificationDate]], @"restart does not rewrite config");
        NSDictionary* first = CLCreateExport(@{@"CurrentCapacity":@59}, &error);
        NSDictionary* second = CLCreateExport(@{@"CurrentCapacity":@58}, &error);
        check(first && second && ![first[@"directory"] isEqual:second[@"directory"]], @"exports have independent permanent directories");
        check([bytes([first[@"directory"] stringByAppendingPathComponent:@"aldente.log"]) isEqual:savedLog], @"export contains full log");
        check([bytes([first[@"directory"] stringByAppendingPathComponent:@"configuration.plist"]) isEqual:savedConfig], @"export includes exact configuration");
        check([CLStorageInfo()[@"exports"] count] == 2, @"exports discoverable after restart");
        check(CLWriteConfigurationValues(@{@"temp_mode":@1, @"charge_temp_below":@50, @"charge_temp_above":@95}, &error), @"atomic temperature conversion");
        check([CLReadConfiguration(&error)[@"charge_temp_above"] intValue] == 95, @"converted limits saved");
        // Cross-process readers/writers emulate the daemon and native overlay.
        pid_t child = fork();
        if (child == 0) {
            execl(argv[0], argv[0], "--writer", (char*)NULL);
            _exit(3);
        }
        check(child > 0, @"fork writer");
        for (int i = 0; i < 30; i++) {
            check(CLWriteConfiguration(@"parent", @(i), &error), @"parent config write");
            check(CLAppendLog(@"parent完整行\n", &error), @"parent append");
        }
        int status = 0;
        waitpid(child, &status, 0);
        check(WIFEXITED(status) && WEXITSTATUS(status) == 0, @"child writer success");
        NSDictionary* concurrent = CLReadConfiguration(&error);
        check([concurrent[@"parent"] intValue] == 29 && [concurrent[@"child"] intValue] == 29, @"concurrent configuration has no lost updates");
        log = CLReadLogTail(65536, &error);
        check([[log componentsSeparatedByString:@"child完整行\n"] count] == 31, @"all child log lines retained");
        check([[log componentsSeparatedByString:@"parent完整行\n"] count] == 31, @"all parent log lines retained");
        check(CLReadLogTail(24, &error) != nil, @"UTF-8 log tail readable");
        // A corrupt file must never be replaced by defaults or a settings write.
        NSString* active = [root stringByAppendingPathComponent:@"aldente.conf"];
        [@"corrupt configuration" writeToFile:active atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSData* corrupt = bytes(active);
        error = nil;
        check(!CLReadConfiguration(&error) && error, @"corruption reported");
        error = nil;
        check(!CLWriteConfiguration(@"enable", @YES, &error), @"corrupt configuration is not overwritten");
        check([corrupt isEqual:bytes(active)], @"corrupt original retained byte-for-byte");
        check([fm fileExistsAtPath:[first[@"directory"] stringByAppendingPathComponent:@"configuration.json"]], @"old export survives changes and corruption");
        NSLog(@"PASS: migration, restart persistence, append, immutable exports, revisions, atomic conversion, concurrent writers, UTF-8 tail, corrupt-file preservation");
    }
    return 0;
}
