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

NSString *const RCImageStoreWillStartRequestNotification =
    @"RCImageStoreWillStartRequestNotification";
NSString *const RCImageStoreDidFinishRequestNotification =
    @"RCImageStoreWillFinishRequestNotification";

@interface RCImageStoreRequest ()

@property(nonatomic) CGSize size;
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
{
    RCImageStoreRequest *aReq = [[RCImageStoreRequest alloc] init];
    aReq.size = size;
    aReq.delegate = delegate;
    aReq.completionHandler = handler;
    [self.delegates addObject:aReq];
    return aReq;
}

@end

@interface RCImageStore ()

- (void)postNotificationName:(NSString *)theName request:(NSURLRequest *)theRequest;

@property(nonatomic, strong) NSMapTable *cache;
@property(nonatomic, strong) NSMutableDictionary *mimeTypes;
@property(nonatomic, strong) NSMutableSet *networkRequests;
@property(nonatomic, strong) NSMapTable *requestsByURL;

// Used for testing

@end

@implementation RCImageStore {
    CGColorRef _predecodingBackgroundColor;
}

- (id)init
{
    if (self = [super init]) {
        self.cache = [NSMapTable strongToWeakObjectsMapTable];
        self.mimeTypes = [NSMutableDictionary dictionary];
        self.networkRequests = [NSMutableSet set];
        self.requestsByURL = [NSMapTable strongToStrongObjectsMapTable];

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
                            delegate:theDelegate
                   completionHandler:nil];
}

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                                    delegate:(id<RCImageStoreDelegate>)theDelegate

{
    return
        [self requestImageWithURL:theURL size:theSize delegate:theDelegate completionHandler:nil];
}

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                           completionHandler:(RCImageStoreCompletionHandler)handler
{
    return [self requestImageWithURL:theURL size:CGSizeZero delegate:nil completionHandler:handler];
}

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                           completionHandler:(RCImageStoreCompletionHandler)handler
{
    return [self requestImageWithURL:theURL size:theSize delegate:nil completionHandler:handler];
}

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                        size:(CGSize)theSize
                                    delegate:(id<RCImageStoreDelegate>)theDelegate
                           completionHandler:(RCImageStoreCompletionHandler)handler

{
    RCImageStoreRequest *request = NULL;

    id theKey = [self cacheKeyForURL:theURL size:theSize];

    RCImage *image;
    @synchronized(self)
    {
        image = (RCImage *)[self.cache objectForKey:theKey];
    }
    if (image) {
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
            [self.requestsByURL setObject:pendingRequest forKey:theKey];
        }
        request = [pendingRequest addDelegate:theDelegate withHandler:handler size:theSize];
        if (submit) {
            dispatch_async(dispatch_get_bg_queue(), ^{ [self performRequest:pendingRequest]; });
        }
    }

    return request;
}

- (void)notifyDelegate:(RCImageStoreInternalRequest *)aRequest
{
    // Always called from a bg thread
    RCImage *image = aRequest.image;
    NSURL *theURL = aRequest.URL;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (RCImageStoreRequest *aReq in aRequest.delegates) {
            if (aReq.cancelled) {
                continue;
            }
            if (aReq.size.width <= 0 || aReq.size.height <= 0
                || CGSizeEqualToSize(image.size, aReq.size)) {
                // No resizing needed, send the image as is.
                [aReq didReceiveImage:image withURL:theURL imageStore:self];
                continue;
            }
            // Go into background to resize, cache the resized image and go
            // back into the main thread to call back the delegate.
            [self resizeImage:image withDelegateRequest:aReq data:aRequest.data URL:theURL];
        }
        [self.requestsByURL removeObjectForKey:theURL];
    });
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
    [self.requestsByURL removeObjectForKey:aRequest.URL];
}

- (void)resizeImage:(RCImage *)theImage
    withDelegateRequest:(RCImageStoreRequest *)theRequest
                   data:(NSData *)data
                    URL:(NSURL *)URL
{
    dispatch_async(dispatch_get_bg_queue(), ^{
        @autoreleasepool
        {
            RCImage *resizedImage = [self resizeImage:theImage toSize:theRequest.size];
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
                        size:theRequest.size];
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
                                     theImage = [[RCImage alloc] initWithData:data];
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
                                                         size:CGSizeZero];

                                             theRequest.data = data;
                                             theRequest.image = preparedImage;

                                             [self notifyDelegate:theRequest];
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
        NSData *theData = nil;
        RCImage *theImage = [self cachedImageWithURL:theURL size:CGSizeZero data:&theData];
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

- (RCImage *)resizeImage:(RCImage *)image toSize:(CGSize)theSize
{
#if TARGET_OS_IPHONE
    CGImageRef cgImage = image.CGImage;
#else
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
#endif
    CGSize imageSize = CGSizeMake(CGImageGetWidth(cgImage), CGImageGetHeight(cgImage));
    CGColorSpaceRef colorspace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, theSize.width, theSize.height, 8, 0, colorspace,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedFirst);

    // Scale and move
    CGFloat widthRatio = theSize.width / imageSize.width;
    CGFloat heightRatio = theSize.height / imageSize.height;

    CGFloat ratio;
    CGPoint trans = CGPointZero;
    if (widthRatio < heightRatio) {
        // Crop width
        ratio = heightRatio;
        trans.x = (imageSize.width * ratio - theSize.width) / 2;
    } else {
        // Crop height
        ratio = widthRatio;
        trans.y = (imageSize.height * ratio - theSize.height) / 2;
    }
    CGContextTranslateCTM(ctx, -trans.x, -trans.y);
    CGContextScaleCTM(ctx, ratio, ratio);

    CGContextDrawImage(ctx, CGRectMake(0, 0, imageSize.width, imageSize.height), cgImage);
    CGImageRef imageRef = CGBitmapContextCreateImage(ctx);
#if TARGET_OS_IPHONE
    UIImage *resized = [UIImage imageWithCGImage:imageRef];
#else
    NSImage *resized = [[NSImage alloc] initWithCGImage:imageRef size:theSize];
#endif
    CGColorSpaceRelease(colorspace);
    CGContextRelease(ctx);
    CGImageRelease(imageRef);
    return resized;
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
                                                 alphaInfo | kCGBitmapByteOrder32Little);
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
    return [self cachedImageWithURL:theURL size:CGSizeZero data:nil];
}

- (RCImage *)cachedImageWithURL:(NSURL *)theURL size:(CGSize)theSize data:(NSData **)outData
{
    id theKey = [self cacheKeyForURL:theURL size:theSize];
    RCImage *theImage = nil;
    @synchronized(self)
    {
        theImage = [self.cache objectForKey:theKey];
    }
    if (!theImage) {
        RCURLCache *sharedCache = [RCURLCache sharedCache];
        NSData *theData = [sharedCache cachedDataForURL:[self sizedURL:theURL size:theSize]];
        if (!theData && theSize.width > 0 && theSize.height > 0) {
            // At this point we're looking for the original image, so the
            // in-memory cache key needs to be adjusted.
            theKey = [self cacheKeyForURL:theURL size:CGSizeZero];
            theData = [sharedCache cachedDataForURL:theURL];
        }
        if (theData) {
            if (outData) {
                *outData = theData;
            }
            theImage = [[RCImage alloc] initWithData:theData];
            if (theImage) {
                theImage = [self prepareImage:theImage];
                @synchronized(self)
                {
                    [self.cache setObject:theImage forKey:theKey];
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
    [self cacheImage:theImage withData:theData response:response forURL:theURL size:CGSizeZero];
}

- (void)cacheImage:(RCImage *)theImage
          withData:(NSData *)theData
          response:(NSURLResponse *)response
            forURL:(NSURL *)theURL
              size:(CGSize)theSize
{
    if (!theImage) {
        theImage = [[RCImage alloc] initWithData:theData];
        if (!theImage) {
            return;
        }
    }
    id theKey = [self cacheKeyForURL:theURL size:theSize];
    @synchronized(self)
    {
        [self.cache setObject:theImage forKey:theKey];
    }
    // Modify the URL in case it's stored a resized image
    theURL = [self sizedURL:theURL size:theSize];
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

- (id)cacheKeyForURL:(NSURL *)theURL size:(CGSize)theSize
{
    if (theSize.width <= 0 || theSize.height <= 0) {
        return theURL.absoluteString;
    }
    return [NSString
        stringWithFormat:@"%fx%f-%@", theSize.width, theSize.height, theURL.absoluteString];
}

- (NSURL *)sizedURL:(NSURL *)theURL size:(CGSize)theSize
{
    if (theSize.width > 0 && theSize.height > 0) {
        return
            [NSURL URLWithString:[NSString stringWithFormat:@"%@__image_store_w%f__image_store_h%f",
                                                            theURL.absoluteString, theSize.width,
                                                            theSize.height]];
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
    @synchronized(self)
    {
        [self.cache removeAllObjects];
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

@end
