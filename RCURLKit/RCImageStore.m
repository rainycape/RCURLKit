//
//  RCImageStore.m
//  RCURLKit
//
//  Created by Alberto García Hierro on 26/05/09.
//  Copyright (c) 2013 Rainy Cape S.L. See LICENSE file.
//

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

#if TARGET_OS_IPHONE
#import <MobileCoreServices/MobileCoreServices.h>
#import <UIKit/UIKit.h>
#define RCImage UIImage
#else
#import <Cocoa/Cocoa.h>
#define RCImage NSImage
#endif

#import "RCURLCache.h"
#import "RCURLRequest.h"

#import "RCImageStore.h"

#define kNetworkTimeout 60
#define kMaximumNetworkRequests 10

#define dispatch_get_bg_queue() dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)

NSString *const RCImageStoreErrorDomain = @"RCImageStoreErrorDomain";
NSString *const RCImageStoreWillStartRequestNotification =
    @"RCImageStoreWillStartRequestNotification";
NSString *const RCImageStoreDidFinishRequestNotification =
    @"RCImageStoreWillFinishRequestNotification";

@interface RCImageStoreRequest ()

@property(nonatomic) CGSize size;
@property(nonatomic) RCImageStoreResizingType resizingType;
@property(nonatomic, weak) id<RCImageStoreDelegate> delegate;
@property(nonatomic, copy) RCImageStoreCompletionHandler completionHandler;
@property(nonatomic) BOOL cancelled;

@end

@implementation RCImageStoreRequest

- (void)cancel
{
    self.cancelled = YES;
}

- (void)didReceiveImage:(RCImage *)theImage
                withURL:(NSURL *)theURL
             imageStore:(RCImageStore *)imageStore
{
    if (self.completionHandler) {
        self.completionHandler(theImage, theURL, nil);
    } else {
        [self.delegate imageStore:imageStore didReceiveImage:theImage withURL:theURL];
    }
}

- (void)failedWithURL:(NSURL *)theURL
                error:(NSError *)theError
           imageStore:(RCImageStore *)imageStore
{
    if (self.completionHandler) {
        self.completionHandler(nil, theURL, theError);
    } else if ([self.delegate respondsToSelector:@selector(imageStore:failedWithURL:error:)]) {
        [self.delegate imageStore:imageStore failedWithURL:theURL error:theError];
    }
}

- (BOOL)requiresResizing
{
    return _size.width > 0 || _size.height > 0;
}

@end

@interface RCImageStoreInternalRequest : NSObject

@property(nonatomic, strong) NSURL *URL;
@property(nonatomic, strong) RCImage *image;
@property(nonatomic, strong) NSData *data;
@property(nonatomic, strong) NSError *error;
@property(nonatomic, strong) NSMutableArray *delegates;

@end

@implementation RCImageStoreInternalRequest

- (id)initWithURL:(NSURL *)theURL
{
    if ((self = [super init])) {
        [self setURL:theURL];
        self.delegates = [NSMutableArray array];
    }
    return self;
}

- (RCImageStoreRequest *)addDelegate:(id<RCImageStoreDelegate>)delegate
                         withHandler:(RCImageStoreCompletionHandler)handler
                                size:(CGSize)size
                        resizingType:(RCImageStoreResizingType)resizingType
{
    RCImageStoreRequest *aReq = [[RCImageStoreRequest alloc] init];
    aReq.size = size;
    aReq.resizingType = resizingType;
    aReq.delegate = delegate;
    aReq.completionHandler = handler;
    [self.delegates addObject:aReq];
    return aReq;
}

@end

@interface RCImageStore ()

- (void)postNotificationName:(NSString *)theName request:(NSURLRequest *)theRequest;

@property(nonatomic, strong) NSMutableDictionary *cacheLRU;
@property(nonatomic, strong) NSMutableDictionary *mimeTypes;
@property(nonatomic, strong) NSMutableSet *networkRequests;
@property(nonatomic, strong) NSMutableDictionary *requestsByURL;

// Used for testing

@end

@implementation RCImageStore {
    CGColorRef _predecodingBackgroundColor;
    CFMutableDictionaryRef _cache;
}

- (id)init
{
    if (self = [super init]) {
        _cache = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks);
        self.cacheLRU = [[NSMutableDictionary alloc] init];
        self.mimeTypes = [NSMutableDictionary dictionary];
        self.networkRequests = [NSMutableSet set];
        self.requestsByURL = [NSMutableDictionary dictionary];
        [self startGarbageCollection];

#if TARGET_OS_IPHONE
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(didReceiveMemoryWarning:)
                   name:UIApplicationDidReceiveMemoryWarningNotification
                 object:nil];
#endif
    }

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    CGColorRelease(_predecodingBackgroundColor);
    if (_cache) {
        CFRelease(_cache);
        _cache = NULL;
    }
}

#if TARGET_OS_IPHONE

- (UIColor *)predecodingBackgroundColor
{
    if (_predecodingBackgroundColor) {
        return [UIColor colorWithCGColor:_predecodingBackgroundColor];
    }
    return nil;
}

- (void)setPredecodingBackgroundColor:(UIColor *)predecodingBackgroundColor
{
    CGColorRef theColor = CGColorRetain([predecodingBackgroundColor CGColor]);
    CGColorRelease(_predecodingBackgroundColor);
    _predecodingBackgroundColor = theColor;
}

#endif

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                    delegate:(id<RCImageStoreDelegate>)theDelegate
{

    return [self requestImageWithURL:theURL
                                size:CGSizeZero
                        resizingType:RCImageStoreResizingTypeDefault
                            delegate:theDelegate
                   completionHandler:nil];
}

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                                    delegate:(id<RCImageStoreDelegate>)theDelegate

{
    return [self requestImageWithURL:theURL
                                size:theSize
                        resizingType:RCImageStoreResizingTypeDefault
                            delegate:theDelegate
                   completionHandler:nil];
}

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                                resizingType:(RCImageStoreResizingType)resizingType
                                    delegate:(id<RCImageStoreDelegate>)theDelegate

{
    return [self requestImageWithURL:theURL
                                size:theSize
                        resizingType:resizingType
                            delegate:theDelegate
                   completionHandler:nil];
}

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                           completionHandler:(RCImageStoreCompletionHandler)handler
{
    return [self requestImageWithURL:theURL
                                size:CGSizeZero
                        resizingType:RCImageStoreResizingTypeDefault
                            delegate:nil
                   completionHandler:handler];
}

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                           completionHandler:(RCImageStoreCompletionHandler)handler
{
    return [self requestImageWithURL:theURL
                                size:theSize
                        resizingType:RCImageStoreResizingTypeDefault
                            delegate:nil
                   completionHandler:handler];
}

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                                resizingType:(RCImageStoreResizingType)resizingType
                           completionHandler:(RCImageStoreCompletionHandler)handler
{
    return [self requestImageWithURL:theURL
                                size:theSize
                        resizingType:resizingType
                            delegate:nil
                   completionHandler:handler];
}

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                                resizingType:(RCImageStoreResizingType)resizingType
                                    delegate:(id<RCImageStoreDelegate>)theDelegate
                           completionHandler:(RCImageStoreCompletionHandler)handler

{
    RCImageStoreRequest *request = NULL;

    id theKey = [self cacheKeyForURL:theURL size:theSize resizingType:resizingType];

    RCImage *image;
    @synchronized((__bridge NSDictionary *)_cache)
    {
        image = (RCImage *)CFDictionaryGetValue(_cache, (void *)theKey);
    }
    if (image) {
        [self updateLRUForKey:theKey];
        if (handler) {
            handler(image, theURL, nil);
        } else {
            [theDelegate imageStore:self didReceiveImage:image withURL:theURL];
        }

    } else {
        RCImageStoreInternalRequest *pendingRequest = [self.requestsByURL objectForKey:theURL];
        BOOL submit = NO;
        if (!pendingRequest) {
            submit = YES;
            pendingRequest = [[RCImageStoreInternalRequest alloc] initWithURL:theURL];
            if (theURL) {
                [self.requestsByURL setObject:pendingRequest forKey:theURL];
            }
        }
        request = [pendingRequest addDelegate:theDelegate
                                  withHandler:handler
                                         size:theSize
                                 resizingType:resizingType];
        if (submit) {
            dispatch_async(dispatch_get_bg_queue(), ^{ [self performRequest:pendingRequest]; });
        }
    }

    return request;
}

- (void)notifyDelegate:(RCImageStoreInternalRequest *)aRequest
{
    // Always called from the main thread
    RCImage *image = aRequest.image;
    NSURL *theURL = aRequest.URL;
    for (RCImageStoreRequest *aReq in aRequest.delegates) {
        if (aReq.cancelled) {
            continue;
        }
        if ((aReq.size.width <= 0 && aReq.size.height <= 0)
            || CGSizeEqualToSize(image.size, aReq.size)) {
            // No resizing needed, send the image as is.
            [aReq didReceiveImage:image withURL:theURL imageStore:self];
            continue;
        }
        // Check if only one dimesion was specified
        if (aReq.size.width <= 0) {
            CGFloat ratio = aReq.size.height / image.size.height;
            aReq.size = CGSizeMake(roundf(image.size.width * ratio), aReq.size.height);
        }
        if (aReq.size.height <= 0) {
            CGFloat ratio = aReq.size.width / image.size.width;
            aReq.size = CGSizeMake(aReq.size.width, roundf(image.size.height * ratio));
        }
        // Go into background to resize, cache the resized image and go
        // back into the main thread to call back the delegate.
        [self resizeImage:image withDelegateRequest:aReq data:aRequest.data URL:theURL];
    }
    [self finishRequest:aRequest];
}

- (void)notifyFailureToDelegate:(RCImageStoreInternalRequest *)aRequest
{
    NSURL *theURL = aRequest.URL;
    NSError *theError = aRequest.error;
    for (RCImageStoreRequest *aReq in aRequest.delegates) {
        if (aReq.cancelled) {
            continue;
        }
        [aReq failedWithURL:theURL error:theError imageStore:self];
    }
    [self finishRequest:aRequest];
}

- (void)finishRequest:(RCImageStoreInternalRequest *)aRequest
{
    if (aRequest.URL) {
        [self.requestsByURL removeObjectForKey:aRequest.URL];
    }
}

- (void)resizeImage:(RCImage *)theImage
    withDelegateRequest:(RCImageStoreRequest *)theRequest
                   data:(NSData *)data
                    URL:(NSURL *)URL
{
    dispatch_async(dispatch_get_bg_queue(), ^{
        @autoreleasepool
        {
            NSURL *cacheURL = [self cacheURLWithURL:URL
                                               size:theRequest.size
                                       resizingType:theRequest.resizingType];
            RCImage *cachedImage = [self cachedImageWithURL:cacheURL];
            if (cachedImage) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!theRequest.cancelled) {
                        [theRequest didReceiveImage:cachedImage withURL:URL imageStore:self];
                    }
                });
                return;
            }
            RCImage *resizedImage = [self resizeImage:theImage
                                               toSize:theRequest.size
                                         resizingType:theRequest.resizingType];
            NSData *resizedData = nil;
            NSString *mimeType = nil;
            if (data) {
                mimeType = [self imageFormatWithData:data];
                if (mimeType) {
                    @synchronized(self.mimeTypes)
                    {
                        [self.mimeTypes setObject:mimeType forKey:URL.absoluteString];
                    }
                }
            } else {
                @synchronized(self.mimeTypes)
                {
                    mimeType = [self.mimeTypes objectForKey:URL.absoluteString];
                }
            }
            if ([mimeType isEqualToString:@"image/png"]) {
                resizedData = [self encodePNGImage:resizedImage];
            } else {
                resizedData = [self encodeJPEGImage:resizedImage quality:0.75];
            }
            [self cacheImage:resizedImage
                    withData:resizedData
                    response:nil
                      forURL:URL
                        size:theRequest.size
                resizingType:theRequest.resizingType];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!theRequest.cancelled) {
                    [theRequest didReceiveImage:resizedImage withURL:URL imageStore:self];
                }
            });
        }
    });
}

- (void)reallyStartFetchingImageWithRequest:(RCImageStoreInternalRequest *)theRequest
{
    NSURL *theURL = [theRequest URL];
    NSMutableURLRequest *aRequest = [NSMutableURLRequest requestWithURL:theURL];
    [aRequest setCachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData];
    if ([self userAgent]) {
        [aRequest setValue:[self userAgent] forHTTPHeaderField:@"User-Agent"];
    }
    [aRequest setTimeoutInterval:kNetworkTimeout];
    [self postNotificationName:RCImageStoreWillStartRequestNotification request:aRequest];
    [RCURLRequest requestWithRequest:aRequest
                             handler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                 RCImage *theImage = nil;
                                 if (!error && (![self requiresOKResponse]
                                                || HTTP_RESPONSE_IS_OK(response))) {
                                     theImage = [self imageWithData:data];
                                 }
                                 if (theImage) {
                                     dispatch_async(dispatch_get_bg_queue(), ^{
                                         @autoreleasepool
                                         {
                                             RCImage *preparedImage = [self prepareImage:theImage];
                                             [self cacheImage:preparedImage
                                                     withData:data
                                                     response:response
                                                       forURL:theURL
                                                         size:CGSizeZero
                                                 resizingType:RCImageStoreResizingTypeDefault];

                                             theRequest.data = data;
                                             theRequest.image = preparedImage;

                                             dispatch_async(dispatch_get_main_queue(),
                                                            ^{ [self notifyDelegate:theRequest]; });
                                         }
                                     });
                                 } else {
                                     theRequest.error = error;
                                     [self notifyFailureToDelegate:theRequest];
                                 }
                                 [self postNotificationName:RCImageStoreDidFinishRequestNotification
                                                    request:aRequest];
                                 [self.networkRequests removeObject:theRequest];
                             }];
}

- (void)startFetchingImageWithRequest:(RCImageStoreInternalRequest *)theRequest
{
    if ([self.networkRequests count] < kMaximumNetworkRequests) {
        [self.networkRequests addObject:theRequest];
        [self reallyStartFetchingImageWithRequest:theRequest];
    } else {
        int64_t delayInSeconds = 0.1;
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(),
                       ^(void) { [self startFetchingImageWithRequest:theRequest]; });
    }
}

- (void)performRequest:(RCImageStoreInternalRequest *)theRequest
{
    @autoreleasepool
    {
        NSURL *theURL = [theRequest URL];
        if (!theURL) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey : NSLocalizedString(@"nil URL", nil),
            };
            theRequest.error =
                [NSError errorWithDomain:RCImageStoreErrorDomain code:0 userInfo:userInfo];
            dispatch_async(dispatch_get_main_queue(),
                           ^{ [self notifyFailureToDelegate:theRequest]; });
            return;
        }
        if (theRequest.delegates.count == 1
            && [[theRequest.delegates objectAtIndex:0] requiresResizing]) {
            // Check if we can serve this from cache without loading the original image
            RCImageStoreRequest *delegateRequest = [theRequest.delegates objectAtIndex:0];
            RCImage *resizedImage = [self cachedImageWithURL:theURL
                                                        size:delegateRequest.size
                                                resizingType:delegateRequest.resizingType
                                                        data:nil];
            if (resizedImage) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [delegateRequest didReceiveImage:resizedImage withURL:theURL imageStore:self];
                    [self finishRequest:theRequest];
                });
                return;
            }
        }
        NSData *theData = nil;
        RCImage *theImage = [self cachedImageWithURL:theURL
                                                size:CGSizeZero
                                        resizingType:RCImageStoreResizingTypeDefault
                                                data:&theData];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (theImage) {
                theRequest.data = theData;
                theRequest.image = theImage;
                [self notifyDelegate:theRequest];
            } else {
                [self startFetchingImageWithRequest:theRequest];
            }
        });
    }
}

- (RCImage *)resizeImage:(RCImage *)image
                  toSize:(CGSize)theSize
            resizingType:(RCImageStoreResizingType)resizingType
{
#if TARGET_OS_IPHONE
    CGImageRef cgImage = image.CGImage;
#else
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
#endif
    CGImageRef imageRef = NULL;
    if (self.resizer) {
        imageRef =
            [self.resizer imageByResizingImage:cgImage toSize:theSize resizingType:resizingType];
    }
    if (!imageRef) {
        imageRef = [self imageByResizingImage:cgImage toSize:theSize resizingType:resizingType];
    }
    RCImage *resized = [self imageWithCGImage:imageRef];
    return resized;
}

- (CGImageRef)imageByResizingImage:(CGImageRef)theImage
                            toSize:(CGSize)theSize
                      resizingType:(RCImageStoreResizingType)resizingType
{
    CGSize imageSize = CGSizeMake(CGImageGetWidth(theImage), CGImageGetHeight(theImage));
    CGColorSpaceRef colorspace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, theSize.width, theSize.height, 8, 0, colorspace,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedFirst);

    // Scale and move
    CGFloat widthRatio = theSize.width / imageSize.width;
    CGFloat heightRatio = theSize.height / imageSize.height;

    CGFloat ratio = 1;
    CGPoint trans = CGPointZero;
    switch (resizingType) {
    case RCImageStoreResizingTypeCenterCrop:
        if (widthRatio < heightRatio) {
            // Crop width
            ratio = heightRatio;
            trans.x = (imageSize.width * ratio - theSize.width) / 2;
        } else {
            // Crop height
            ratio = widthRatio;
            trans.y = (imageSize.height * ratio - theSize.height) / 2;
        }
        break;
    case RCImageStoreResizingTypeFit:
        if (widthRatio < heightRatio) {
            // Fit width
            ratio = widthRatio;
            trans.y = (imageSize.height * ratio - theSize.height) / 2;
        } else {
            // Fit height
            ratio = heightRatio;
            trans.x = (imageSize.width * ratio - theSize.width) / 2;
        }
        break;
    }
    CGContextTranslateCTM(ctx, -trans.x, -trans.y);
    CGContextScaleCTM(ctx, ratio, ratio);

    CGContextDrawImage(ctx, CGRectMake(0, 0, imageSize.width, imageSize.height), theImage);
    CGImageRef imageRef = CGBitmapContextCreateImage(ctx);
    CGColorSpaceRelease(colorspace);
    CGContextRelease(ctx);
    return imageRef;
}

- (RCImage *)prepareImage:(RCImage *)image
{
#if TARGET_OS_IPHONE
    if ([self predecode]) {
        CGImageRef imageRef = [image CGImage];
        size_t width = CGImageGetWidth(imageRef);
        size_t height = CGImageGetHeight(imageRef);
        CGColorSpaceRef colorspace = CGColorSpaceCreateDeviceRGB();
        CGImageAlphaInfo alphaInfo = kCGImageAlphaPremultipliedFirst;
        if (_predecodingBackgroundColor) {
            alphaInfo = kCGImageAlphaNoneSkipFirst;
        }
        CGContextRef ctx = CGBitmapContextCreate(NULL, width, height, 8, width * 4, colorspace,
                                                 alphaInfo | kCGBitmapByteOrder32Host);
        CGRect imageRect = CGRectMake(0, 0, width, height);
        if (_predecodingBackgroundColor) {
            CGContextSetFillColorWithColor(ctx, _predecodingBackgroundColor);
            CGContextFillRect(ctx, imageRect);
        }
        CGContextDrawImage(ctx, imageRect, imageRef);
        CGImageRef drawnImage = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        CGColorSpaceRelease(colorspace);
        UIImage *preparedImage = [[UIImage alloc] initWithCGImage:drawnImage];
        CGImageRelease(drawnImage);
        return preparedImage;
    }
#endif
    return image;
}

- (RCImage *)cachedImageWithURL:(NSURL *)theURL
{
    return [self cachedImageWithURL:theURL
                               size:CGSizeZero
                       resizingType:RCImageStoreResizingTypeDefault
                               data:nil];
}

- (RCImage *)cachedImageWithURL:(NSURL *)theURL
                           size:(CGSize)theSize
                   resizingType:(RCImageStoreResizingType)resizingType
                           data:(NSData **)outData
{
    id theKey = [self cacheKeyForURL:theURL size:theSize resizingType:resizingType];
    RCImage *theImage = nil;
    @synchronized((__bridge NSDictionary *)_cache)
    {
        theImage = CFDictionaryGetValue(_cache, (void *)theKey);
    }
    if (!theImage) {
        RCURLCache *sharedCache = [RCURLCache sharedCache];
        NSURL *cacheURL = [self cacheURLWithURL:theURL size:theSize resizingType:resizingType];
        NSData *theData = [sharedCache cachedDataForURL:cacheURL];
        if (theData) {
            if (outData) {
                *outData = theData;
            }
            theImage = [self imageWithData:theData];
            if (theImage) {
                theImage = [self prepareImage:theImage];
                @synchronized((__bridge NSDictionary *)_cache)
                {
                    CFDictionarySetValue(_cache, (void *)theKey, (void *)theImage);
                    [self updateLRUForKey:theKey];
                }
            }
        }
    }
    return theImage;
}

- (void)cacheImage:(RCImage *)theImage
          withData:(NSData *)theData
          response:(NSURLResponse *)response
            forURL:(NSURL *)theURL
{
    [self cacheImage:theImage
            withData:theData
            response:response
              forURL:theURL
                size:CGSizeZero
        resizingType:RCImageStoreResizingTypeDefault];
}

- (void)cacheImage:(RCImage *)theImage
          withData:(NSData *)theData
          response:(NSURLResponse *)response
            forURL:(NSURL *)theURL
              size:(CGSize)theSize
      resizingType:(RCImageStoreResizingType)resizingType
{
    if (!theImage) {
        theImage = [self imageWithData:theData];
        if (!theImage) {
            return;
        }
    }
    if (!theData) {
        if (theImage) {
            theData = [self encodePNGImage:theImage];
        }
        if (!theData) {
            return;
        }
    }
    id theKey = [self cacheKeyForURL:theURL size:theSize resizingType:resizingType];
    @synchronized((__bridge NSDictionary *)_cache)
    {
        CFDictionarySetValue(_cache, (void *)theKey, (void *)theImage);
    }
    // Modify the URL in case it's stored a resized image
    theURL = [self cacheURLWithURL:theURL size:theSize resizingType:resizingType];
    NSURLRequest *theRequest = [NSURLRequest requestWithURL:theURL];
    if (!response) {
        NSString *imageFormat = [self imageFormatWithData:theData];
        if (imageFormat) {
            NSDictionary *headerFields = @{
                @"Content-Type" : [@"image/" stringByAppendingString:imageFormat]
            };
            response = [[NSHTTPURLResponse alloc] initWithURL:theURL
                                                   statusCode:200
                                                  HTTPVersion:@"HTTP/1.1"
                                                 headerFields:headerFields];
        }
    }
    if (response) {
        [[RCURLCache sharedCache] storeResponse:response withData:theData forRequest:theRequest];
    }
}

- (id)cacheKeyForURL:(NSURL *)theURL
                size:(CGSize)theSize
        resizingType:(RCImageStoreResizingType)resizingType
{
    if (theSize.width <= 0 && theSize.height <= 0) {
        return theURL.absoluteString;
    }
    return [NSString stringWithFormat:@"%fx%f:%d-%@", theSize.width, theSize.height,
                                      (int)resizingType, theURL.absoluteString];
}

- (NSURL *)cacheURLWithURL:(NSURL *)theURL
                      size:(CGSize)theSize
              resizingType:(RCImageStoreResizingType)resizingType
{
    if (theSize.width > 0 || theSize.height > 0) {
        NSString *URLString =
            [NSString stringWithFormat:@"%@_isw%f_ish%f_ishrt%d", theURL.absoluteString,
                                       theSize.width, theSize.height, (int)resizingType];
        return [NSURL URLWithString:URLString];
    }
    return theURL;
}

- (NSString *)imageFormatWithData:(NSData *)theData
{
    NSString *imageFormat = nil;
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)theData, NULL);
    if (imageSource) {
        if (CGImageSourceGetStatus(imageSource) == kCGImageStatusComplete) {
            CFStringRef imageType = CGImageSourceGetType(imageSource);
            if (imageType) {
                imageFormat = (NSString *)CFBridgingRelease(
                    UTTypeCopyPreferredTagWithClass(imageType, kUTTagClassMIMEType));
            }
        }
        CFRelease(imageSource);
    }
    return imageFormat;
}

- (void)postNotificationName:(NSString *)theName request:(NSURLRequest *)theRequest
{
    NSNotification *aNotification = [NSNotification notificationWithName:theName object:theRequest];
    [[NSNotificationCenter defaultCenter] postNotification:aNotification];
}

- (void)didReceiveMemoryWarning:(NSNotification *)aNotification
{
    /* Empty the cache from the main thread */
    @synchronized((__bridge NSDictionary *)_cache)
    {
        CFDictionaryRemoveAllValues(_cache);
    }
}

#pragma mark - Garbage collection

- (void)startGarbageCollection
{
    __weak RCImageStore *imageStore = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        if (imageStore) {
            [imageStore garbageCollect];
            [imageStore startGarbageCollection];
        }
    });
}

- (void)garbageCollect
{
    // Collect images not used in the last minute held
    // only by the cache dictionary.
    int kMaxLRU = 60;
    @synchronized((__bridge NSDictionary *)_cache)
    {
        time_t now = time(NULL);
        CFIndex count = CFDictionaryGetCount(_cache);
        const void *keys[count];
        const void *values[count];
        CFDictionaryGetKeysAndValues(_cache, keys, values);
        for (CFIndex ii = 0; ii < count; ii++) {
            if (CFGetRetainCount(values[ii]) == 1) {
                // Only the cache is retaining this image, check LRU
                // and remove it appropriate.
                id aKey = (__bridge id)(keys[ii]);
                time_t lru = [[self.cacheLRU objectForKey:aKey] longValue];
                if (lru == 0 || now - lru < -kMaxLRU) {
                    CFDictionaryRemoveValue(_cache, keys[ii]);
                }
            }
        }
    }
}

- (void)updateLRUForKey:(id)aKey
{
    @synchronized(self.cacheLRU)
    {
        time_t now = time(NULL);
        [self.cacheLRU setObject:@(now) forKey:aKey];
    }
}

#pragma mark - Image loading

- (RCImage *)imageWithData:(NSData *)data
{
    // Unfortunately, it seems [[UIImage alloc] initWithData:] is not thread safe
    // in iOS 8, which is probably a bug since it worked fine in previous versions.
    //
    // The culprit seems some interaction with UITraitCollection, which causes either
    // a leak or a double free (or both sometimes).
    //
    // Workaround: decode the image using ImageIO and then create a platform image from it.

    RCImage *image = nil;
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (imageSource) {
        if (CGImageSourceGetStatus(imageSource) == kCGImageStatusComplete) {
            CFDictionaryRef options = CFDictionaryCreate(
                kCFAllocatorDefault, (void *)&kCGImageSourceShouldCacheImmediately,
                (void *)&kCFBooleanTrue, 1, NULL, NULL);
            CGImageRef imageRef = CGImageSourceCreateImageAtIndex(imageSource, 0, options);
            CFRelease(options);
            if (imageRef) {
                image = [self imageWithCGImage:imageRef];
                CGImageRelease(imageRef);
            }
        }
        CFRelease(imageSource);
    }
    return image;
}

- (RCImage *)imageWithCGImage:(CGImageRef)imageRef
{
    @synchronized(self)
    {
#if TARGET_OS_IPHONE
        // Making this method not thread safe is just retarded, Apple
        return [UIImage imageWithCGImage:imageRef];
#else
        return [[NSImage alloc] initWithCGImage:imageRef size:NSZeroSize];
#endif
    }
}

#pragma mark - Image encoding

- (NSData *)encodePNGImage:(RCImage *)theImage
{
#if TARGET_OS_IPHONE
    return UIImagePNGRepresentation(theImage);
#else
    return [self encodeImage:theImage fileType:NSPNGFileType properties:nil];
#endif
}

- (NSData *)encodeJPEGImage:(RCImage *)theImage quality:(CGFloat)quality
{
#if TARGET_OS_IPHONE
    return UIImageJPEGRepresentation(theImage, quality);
#else
    return [self encodeImage:theImage
                    fileType:NSJPEGFileType
                  properties:@{
                      NSImageCompressionFactor : @(quality)
                  }];
#endif
}

#if !TARGET_OS_IPHONE

- (NSData *)encodeImage:(NSImage *)theImage
               fileType:(NSBitmapImageFileType)fileType
             properties:(NSDictionary *)theProperties
{
    CGImageRef imageRef = [theImage CGImageForProposedRect:NULL context:nil hints:nil];
    NSBitmapImageRep *theRep = [[NSBitmapImageRep alloc] initWithCGImage:imageRef];
    [theRep setSize:theImage.size];
    return [theRep representationUsingType:fileType properties:theProperties];
}

#endif

#pragma mark - Singleton boilerplate

+ (RCImageStore *)sharedStore
{
    static RCImageStore *sharedStore = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{ sharedStore = [[self alloc] init]; });
    return sharedStore;
}

#pragma mark - Class methods

+ (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                    delegate:(id<RCImageStoreDelegate>)theDelegate
{
    return [[self sharedStore] requestImageWithURL:theURL delegate:theDelegate];
}

+ (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                                    delegate:(id<RCImageStoreDelegate>)theDelegate
{
    return [[self sharedStore] requestImageWithURL:theURL size:theSize delegate:theDelegate];
}

+ (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                                resizingType:(RCImageStoreResizingType)resizingType
                                    delegate:(id<RCImageStoreDelegate>)theDelegate
{
    return [[self sharedStore] requestImageWithURL:theURL
                                              size:theSize
                                      resizingType:resizingType
                                          delegate:theDelegate];
}

+ (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                           completionHandler:(RCImageStoreCompletionHandler)handler
{
    return [[self sharedStore] requestImageWithURL:theURL completionHandler:handler];
}

+ (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                           completionHandler:(RCImageStoreCompletionHandler)handler
{
    return [[self sharedStore] requestImageWithURL:theURL size:theSize completionHandler:handler];
}

+ (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                                resizingType:(RCImageStoreResizingType)resizingType
                           completionHandler:(RCImageStoreCompletionHandler)handler
{
    return [[self sharedStore] requestImageWithURL:theURL
                                              size:theSize
                                      resizingType:resizingType
                                 completionHandler:handler];
}

@end
