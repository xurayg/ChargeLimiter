#pragma once
#import <UIKit/UIKit.h>

UIViewController* CLCreateNativeInterface(void);

@interface CLNativeHUD : UIControl
- (void)startUpdating;
- (void)stopUpdating;
@end
