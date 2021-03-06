//
//  RCImageStore.h
//  RCURLKit
//
//  Created by Alberto García Hierro on 26/05/09.
//  Copyright (c) 2013 Rainy Cape S.L. See LICENSE file.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, RCImageStoreResizingType) {
    RCImageStoreResizingTypeCenterCrop,
    RCImageStoreResizingTypeFit,

    RCImageStoreResizingTypeDefault = RCImageStoreResizingTypeCenterCrop,
};

#if TARGET_OS_IPHONE

#import <UIKit/UIKit.h>

@class UIImage;
typedef void (^RCImageStoreCompletionHandler)(UIImage *image, NSURL *URL, NSError *error);

#else

#import <Cocoa/Cocoa.h>

@class NSImage;
typedef void (^RCImageStoreCompletionHandler)(NSImage *image, NSURL *URL, NSError *error);

#endif

extern NSString *const RCImageStoreErrorDomain;
extern NSString *const RCImageStoreWillStartRequestNotification;
extern NSString *const RCImageStoreDidFinishRequestNotification;

@class RCImageStore;
@protocol RCImageResizer;

@interface RCImageStoreRequest : NSObject

- (void)cancel;

@end

@protocol RCImageStoreDelegate <NSObject>

@required
#if TARGET_OS_IPHONE
- (void)imageStore:(RCImageStore *)imageStore
    didReceiveImage:(UIImage *)theImage
            withURL:(NSURL *)theURL;
#else
- (void)imageStore:(RCImageStore *)imageStore
    didReceiveImage:(NSImage *)theImage
            withURL:(NSURL *)theURL;
#endif

@optional
- (void)imageStore:(RCImageStore *)imageStore
     failedWithURL:(NSURL *)theURL
             error:(NSError *)theError;

@end

@interface RCImageStore : NSObject {
}

@property(nonatomic, strong) NSString *userAgent;
@property(nonatomic, getter=requiresOKResponse) BOOL requireOKResponse;
@property(nonatomic, strong) id<RCImageResizer> resizer;
@property(nonatomic) BOOL predecode;
#if TARGET_OS_IPHONE
@property(nonatomic, retain) UIColor *predecodingBackgroundColor;
#endif

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                    delegate:(id<RCImageStoreDelegate>)theDelegate;

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                                    delegate:(id<RCImageStoreDelegate>)theDelegate;

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                                resizingType:(RCImageStoreResizingType)resizingType
                                    delegate:(id<RCImageStoreDelegate>)theDelegate;

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                           completionHandler:(RCImageStoreCompletionHandler)handler;

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                           completionHandler:(RCImageStoreCompletionHandler)handler;

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                                resizingType:(RCImageStoreResizingType)resizingType
                           completionHandler:(RCImageStoreCompletionHandler)handler;

#if TARGET_OS_IPHONE

- (UIImage *)cachedImageWithURL:(NSURL *)theURL;

- (void)cacheImage:(UIImage *)theImage
          withData:(NSData *)theData
          response:(NSURLResponse *)response
            forURL:(NSURL *)theURL;

- (void)purgeImageFromMemory:(UIImage *)theImage;

#else

- (NSImage *)cachedImageWithURL:(NSURL *)theURL;
- (void)cacheImage:(NSImage *)theImage
          withData:(NSData *)theData
          response:(NSURLResponse *)response
            forURL:(NSURL *)theURL;

- (void)purgeImageFromMemory:(NSImage *)theImage;

#endif

+ (RCImageStore *)sharedStore;

+ (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                    delegate:(id<RCImageStoreDelegate>)theDelegate;

+ (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                                    delegate:(id<RCImageStoreDelegate>)theDelegate;

+ (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                                resizingType:(RCImageStoreResizingType)resizingType
                                    delegate:(id<RCImageStoreDelegate>)theDelegate;

+ (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                           completionHandler:(RCImageStoreCompletionHandler)handler;

+ (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                           completionHandler:(RCImageStoreCompletionHandler)handler;

+ (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                                resizingType:(RCImageStoreResizingType)resizingType
                           completionHandler:(RCImageStoreCompletionHandler)handler;

@end

@protocol RCImageResizer <NSObject>

- (CGImageRef)newImageByResizingImage:(CGImageRef)theImage
                               toSize:(CGSize)theSize
                         resizingType:(RCImageStoreResizingType)resizingType;

@end
