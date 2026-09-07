#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Single worker owns libopenconnect. Control methods only signal its command pipe.
@interface OCEngine : NSObject
- (instancetype)initWithServer:(NSString *)server username:(NSString *)username
                     password:(NSString *)password group:(NSString *)group useDTLS:(BOOL)useDTLS;
/// Blocks on a dedicated worker. Settings callback must copy and apply settings before returning.
- (NSInteger)runWithSettingsHandler:(BOOL (^)(NSDictionary<NSString *, id> *, int))settings
                      eventHandler:(void (^)(NSString *))event;
- (void)cancel;
- (void)updateNetworkAvailable:(BOOL)available reconnect:(BOOL)reconnect;
@property(nonatomic, readonly) BOOL authenticationFailed;
@property(nonatomic, readonly) BOOL certificateFailed;
@property(nonatomic, readonly, copy) NSString *certificateFailureDetail;
@property(nonatomic, readonly) BOOL settingsFailed;
+ (NSString *)version;
@end
NS_ASSUME_NONNULL_END
