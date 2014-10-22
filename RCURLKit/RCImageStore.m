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

NSString *const RCImageStoreWillStartRequestNotification =
    @"RCImageStoreWillStartRequestNotification";
NSString *const RCImageStoreDidFinishRequestNotification =
    @"RCImageStoreWillFinishRequestNotification";

@interface RCImageStoreRequest : NSObject

@property(nonatomic, strong) NSURL *URL;
@property(nonatomic, strong) id userInfo;
@property(nonatomic, strong) NSPointerArray *delegates;

@end

@implementation RCImageStoreRequest

- (id)initWithURL:(NSURL *)theURL delegate:(id<RCImageStoreDelegate>)delegate
{
    if ((self = [super init])) {
        [self setURL:theURL];
        self.delegates = [NSPointerArray weakObjectsPointerArray];
        [self.delegates addPointer:(__bridge void *)(delegate)];
    }
    return self;
}


- (void)addDelegate:(id<RCImageStoreDelegate>)delegate
{
    BOOL found = NO;
    for (id aPointer in self.delegates) {
        if (aPointer == delegate) {
            found = YES;
            break;
        }
    }
    if (!found) {
        [self.delegates addPointer:(__bridge void *)(delegate)];
    }
}

- (void)removeDelegate:(id<RCImageStoreDelegate>)delegate
{
    NSUInteger theIndex = NSNotFound;
    NSUInteger ii = 0;
    for (id aPointer in self.delegates) {
        if (aPointer == delegate) {
            theIndex = ii;
            break;
        }
        ii++;
    }
    if (theIndex != NSNotFound) {
        [self.delegates removePointerAtIndex:theIndex];
    }
}

@end

@interface RCImageStore ()

- (void)postNotificationName:(NSString *)theName request:(NSURLRequest *)theRequest;

@property(nonatomic, strong) NSMapTable *cache;
@property(nonatomic, strong) NSMutableSet *networkRequests;
@property(nonatomic, strong) NSMapTable *requestsByURL;

@end

@implementation RCImageStore {
    CGColorRef _predecodingBackgroundColor;
}

- (id)init
{
    if (self = [super init]) {
        self.cache = [NSMapTable strongToWeakObjectsMapTable];
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

- (RCImageStoreRequest *)requestImageWithURLString:(NSString *)theURLString
                                          delegate:(id<RCImageStoreDelegate>)theDelegate
{
    return [self requestImageWithURL:[NSURL URLWithString:theURLString] delegate:theDelegate];
}

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                    delegate:(id<RCImageStoreDelegate>)theDelegate
{

    RCImageStoreRequest *request = NULL;

    id theKey = [self cacheKeyForURL:theURL];

    RCImage *image;
    @synchronized(self)
    {
        image = (RCImage *)[self.cache objectForKey:theKey];
    }
    if (image) {
        [theDelegate imageStore:self didReceiveImage:image withURL:theURL];

    } else {
        RCImageStoreRequest *pendingRequest = [self.requestsByURL objectForKey:theKey];
        if (pendingRequest) {
            request = pendingRequest;
            [pendingRequest addDelegate:theDelegate];
        } else {
            RCImageStoreRequest *aRequest =
                [[RCImageStoreRequest alloc] initWithURL:theURL delegate:theDelegate];
            [self.requestsByURL setObject:aRequest forKey:theKey];
            request = aRequest;
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                           ^{ [self performRequest:aRequest]; });
        }
    }

    return request;
}

- (void)cancelRequest:(RCImageStoreRequest *)theRequest
         withDelegate:(id<RCImageStoreDelegate>)theDelegate
{
    [theRequest removeDelegate:theDelegate];
}

- (void)notifyDelegate:(RCImageStoreRequest *)aRequest
{
    RCImage *image = [aRequest userInfo];
    NSURL *theURL = [aRequest URL];
    id theKey = [self cacheKeyForURL:theURL];
    @synchronized(self)
    {
        [self.cache setObject:image forKey:theKey];
    }
    [self.requestsByURL removeObjectForKey:theKey];
    for (id<RCImageStoreDelegate> aDelegate in [aRequest delegates]) {
        [aDelegate imageStore:self didReceiveImage:image withURL:theURL];
    }
}

- (void)notifyFailureToDelegate:(RCImageStoreRequest *)aRequest
{
    id theKey = [self cacheKeyForURL:aRequest.URL];
    [self.requestsByURL removeObjectForKey:theKey];
    NSError *theError = [aRequest userInfo];
    for (id<RCImageStoreDelegate> aDelegate in [aRequest delegates]) {
        if ([aDelegate respondsToSelector:@selector(imageStore:failedWithURL:error:)]) {
            [aDelegate imageStore:self failedWithURL:[aRequest URL] error:theError];
        }
    }
}

- (void)reallyStartFetchingImageWithRequest:(RCImageStoreRequest *)theRequest
{
    NSURL *theURL = [theRequest URL];
    NSMutableURLRequest *aRequest = [NSMutableURLRequest requestWithURL:theURL];
    [aRequest setCachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData];
    if ([self userAgent]) {
        [aRequest setValue:[self userAgent] forHTTPHeaderField:@"User-Agent"];
    }
    [aRequest setTimeoutInterval:kNetworkTimeout];
    [self postNotificationName:RCImageStoreWillStartRequestNotification request:aRequest];
    [RCURLRequest
        requestWithRequest:aRequest
                   handler:^(NSData *data, NSURLResponse *response, NSError *error) {
                       RCImage *theImage = nil;
                       if (!error
                           && (![self requiresOKResponse] || HTTP_RESPONSE_IS_OK(response))) {
                           theImage = [[RCImage alloc] initWithData:data];
                       }
                       if (theImage) {
                           theImage = [self prepareImage:theImage];
                           [self cacheImage:theImage withData:data response:response forURL:theURL];
                           [theRequest setUserInfo:theImage];
                           [self notifyDelegate:theRequest];
                       } else {
                           [theRequest setUserInfo:error];
                           [self notifyFailureToDelegate:theRequest];
                       }
                       [self postNotificationName:RCImageStoreDidFinishRequestNotification
                                          request:aRequest];
                       [self.networkRequests removeObject:theRequest];
                   }];
}

- (void)startFetchingImageWithRequest:(RCImageStoreRequest *)theRequest
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

- (void)performRequest:(RCImageStoreRequest *)theRequest
{
    @autoreleasepool
    {
        NSURL *theURL = [theRequest URL];
        RCImage *theImage = [self cachedImageWithURL:theURL];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (theImage) {
                [theRequest setUserInfo:theImage];
                [self notifyDelegate:theRequest];
            } else {
                [self startFetchingImageWithRequest:theRequest];
            }
        });
    }
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
        [image release];
        image = [[UIImage alloc] initWithCGImage:drawnImage];
        CGImageRelease(drawnImage);
    }
#endif
    return image;
}

- (RCImage *)cachedImageWithURL:(NSURL *)theURL
{
    id theKey = [self cacheKeyForURL:theURL];
    RCImage *theImage = nil;
    @synchronized(self)
    {
        theImage = [self.cache objectForKey:theKey];
    }
    if (!theImage) {
        RCURLCache *sharedCache = [RCURLCache sharedCache];
        NSData *theData = [sharedCache cachedDataForURL:theURL];
        if (theData) {
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
    if (!theImage) {
        theImage = [[RCImage alloc] initWithData:theData];
        if (!theImage) {
            return;
        }
    }
    id theKey = [self cacheKeyForURL:theURL];
    @synchronized(self)
    {
        [self.cache setObject:theImage forKey:theKey];
    }
    NSURLRequest *theRequest = [NSURLRequest requestWithURL:theURL];
    if (!response) {
        NSString *imageFormat = nil;
        CGImageSourceRef imageSource
            = CGImageSourceCreateWithData((__bridge CFDataRef)theData, NULL);
        if (imageSource) {
            if (CGImageSourceGetStatus(imageSource) == kCGImageStatusComplete) {
                CFStringRef imageType = CGImageSourceGetType(imageSource);
                if (imageType) {
                    imageFormat = (NSString *)CFBridgingRelease(UTTypeCopyPreferredTagWithClass(
                        imageType, kUTTagClassMIMEType));
                }
            }
            CFRelease(imageSource);
        }
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
{
    return theURL.absoluteString;
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

#pragma mark singleton boilerplate

+ (RCImageStore *)sharedStore
{
    static RCImageStore *sharedStore = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{ sharedStore = [[self alloc] init]; });
    return sharedStore;
}

+ (void)cancelRequest:(RCImageStoreRequest *)theRequest
         withDelegate:(id<RCImageStoreDelegate>)theDelegate
{
    [[self sharedStore] cancelRequest:theRequest withDelegate:theDelegate];
}

+ (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL
                                    delegate:(id<RCImageStoreDelegate>)theDelegate
{
    return [[self sharedStore] requestImageWithURL:theURL delegate:theDelegate];
}

+ (RCImageStoreRequest *)requestImageWithURLString:(NSString *)theURLString
                                          delegate:(id<RCImageStoreDelegate>)theDelegate
{
    return [[self sharedStore] requestImageWithURLString:theURLString delegate:theDelegate];
}

@end
