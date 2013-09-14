//
//  RCImageStore.h
//  RCURLKit
//
//  Created by Alberto García Hierro on 26/05/09.
//  Copyright (c) 2013 Rainy Cape S.L. See LICENSE file.
//

#import <Foundation/Foundation.h>

#if TARGET_OS_IPHONE
@class UIImage;
#else
@class NSImage;
#endif

extern NSString * const RCImageStoreWillStartRequestNotification;
extern NSString * const RCImageStoreDidFinishRequestNotification;

@class RCImageStore;

@class RCImageStoreRequest;

@protocol RCImageStoreDelegate<NSObject>

@required
#if TARGET_OS_IPHONE
- (void)imageStore:(RCImageStore *)imageStore didReceiveImage:(UIImage *)theImage withURL:(NSURL *)theURL;
#else
- (void)imageStore:(RCImageStore *)imageStore didReceiveImage:(NSImage *)theImage withURL:(NSURL *)theURL;
#endif

@optional
- (void)imageStore:(RCImageStore *)imageStore failedWithURL:(NSURL *)theURL error:(NSError *)theError;

@end


@interface RCImageStore : NSObject {
}

@property(nonatomic, retain) NSString *userAgent;
@property(nonatomic, getter = requiresOKResponse) BOOL requireOKResponse;
@property(nonatomic) BOOL predecode;
#if TARGET_OS_IPHONE
@property(nonatomic, retain) UIColor *predecodingBackgroundColor;
#endif

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL delegate:(id<RCImageStoreDelegate>)theDelegate;
- (RCImageStoreRequest *)requestImageWithURLString:(NSString *)theURLString delegate:(id<RCImageStoreDelegate>)theDelegate;
#if TARGET_OS_IPHONE
- (UIImage *)cachedImageWithURL:(NSURL *)theURL;
- (void)cacheImage:(UIImage *)theImage withData:(NSData *)theData response:(NSURLResponse *)response forURL:(NSURL *)theURL;
#else
- (NSImage *)cachedImageWithURL:(NSURL *)theURL;
- (void)cacheImage:(NSImage *)theImage withData:(NSData *)theData response:(NSURLResponse *)response forURL:(NSURL *)theURL;
#endif

- (void)cancelRequest:(RCImageStoreRequest *)theRequest withDelegate:(id<RCImageStoreDelegate>)theDelegate;

+ (RCImageStore *)sharedStore;

@end
