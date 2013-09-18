//
//  RCImageStore.m
//  RCURLKit
//
//  Created by Alberto García Hierro on 26/05/09.
//  Copyright (c) 2013 Rainy Cape S.L. See LICENSE file.
//

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>

#if TARGET_OS_IPHONE
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

NSString * const RCImageStoreWillStartRequestNotification = @"RCImageStoreWillStartRequestNotification";
NSString * const RCImageStoreDidFinishRequestNotification = @"RCImageStoreWillFinishRequestNotification";

@interface RCImageStoreInternalRequest : NSObject {
	CFMutableArrayRef _delegates;
}

@property(nonatomic, retain) NSURL *URL;
@property(nonatomic, retain) id userInfo;
@property(nonatomic, readonly) NSMutableArray *delegates;

@end

@implementation RCImageStoreInternalRequest

- (id)initWithURL:(NSURL *)theURL delegate:(id<RCImageStoreDelegate>)delegate
{
    if ((self = [super init])) {
        [self setURL:theURL];
        _delegates = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
        CFArrayAppendValue(_delegates, delegate);
    }
    return self;
}

- (void)dealloc {
	[_URL release];
    [_userInfo release];
    CFRelease(_delegates);
	[super dealloc];
}

- (void)addDelegate:(id<RCImageStoreDelegate>)delegate
{
    CFIndex idx = CFArrayGetFirstIndexOfValue(_delegates, CFRangeMake(0, CFArrayGetCount(_delegates)), delegate);
    if (idx == kCFNotFound) {
        CFArrayAppendValue(_delegates, delegate);
    }
}

- (void)removeDelegate:(id<RCImageStoreDelegate>)delegate
{
    CFIndex idx = CFArrayGetFirstIndexOfValue(_delegates, CFRangeMake(0, CFArrayGetCount(_delegates)), delegate);
    if (idx != kCFNotFound) {
        CFArrayRemoveValueAtIndex(_delegates, idx);
    }
}

- (NSArray *)delegates
{
    return (NSArray *)_delegates;
}

@end

@interface RCImageStore ()

- (NSUInteger)cacheKeyForURL:(NSURL *)theURL;
- (void)postNotificationName:(NSString *)theName request:(NSURLRequest *)theRequest;

@end

@implementation RCImageStore {
    CFMutableDictionaryRef _cache;
	CFMutableSetRef _requests;
    CFMutableSetRef _networkRequests;
    CFMutableDictionaryRef _requestsByURL;
	NSTimer *_garbageCollectorTimer;
    CGColorRef _predecodingBackgroundColor;
}

- (id)init {
	if (self = [super init]) {
		/* Prevents the keys from being copied */
		_cache = CFDictionaryCreateMutable(NULL, 0, NULL,
										   &kCFTypeDictionaryValueCallBacks);
		_requests = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
        _networkRequests = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
        _requestsByURL = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
		_garbageCollectorTimer = [NSTimer scheduledTimerWithTimeInterval:30 target:self
																selector:@selector(garbageCollect)
																userInfo:nil repeats:YES];
#if TARGET_OS_IPHONE
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveMemoryWarning:)
													 name:UIApplicationDidReceiveMemoryWarningNotification
												   object:nil];
#endif
	}

	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
    [_userAgent release];
	CFRelease(_cache);
	CFRelease(_requests);
    CFRelease(_networkRequests);
    CFRelease(_requestsByURL);
	[_garbageCollectorTimer invalidate];
    CGColorRelease(_predecodingBackgroundColor);
	[super dealloc];
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

- (void)garbageCollect {
	NSThread *thread = [[NSThread alloc] initWithTarget:self
											   selector:@selector(garbageCollectThread)
												 object:nil];
	[thread start];
	[thread release];
}

- (void)garbageCollectThread {
	CFIndex count = CFDictionaryGetCount(_cache);
	if (count > 0) {
		const void *keys[count];
		CFDictionaryGetKeysAndValues(_cache, keys, NULL);
		for (NSInteger ii = count - 1; ii >= 0; --ii) {
			const void *key = keys[ii];
			CFTypeRef obj = CFDictionaryGetValue(_cache, key);
			if (CFGetRetainCount(obj) == 1) {
				/* Only cache_ is retaining the image */
				CFDictionaryRemoveValue(_cache, key);
			}
		}
	}
}

- (RCImageStoreRequest *)requestImageWithURLString:(NSString *)theURLString delegate:(id<RCImageStoreDelegate>)theDelegate {
	return [self requestImageWithURL:[NSURL URLWithString:theURLString] delegate:theDelegate];
}

- (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL delegate:(id<RCImageStoreDelegate>)theDelegate {

	void *request = NULL;

	void *key = (void *)[theURL.absoluteString hash];

	RCImage *image = (RCImage *)CFDictionaryGetValue(_cache, key);
	if (image) {
        [theDelegate imageStore:self didReceiveImage:image withURL:theURL];

	} else {
        RCImageStoreInternalRequest *pendingRequest = CFDictionaryGetValue(_requestsByURL, key);
        if (pendingRequest) {
            request = pendingRequest;
            [pendingRequest addDelegate:theDelegate];
        } else {
            RCImageStoreInternalRequest *aRequest = [[RCImageStoreInternalRequest alloc] initWithURL:theURL delegate:theDelegate];
            CFSetAddValue(_requests, aRequest);
            CFDictionarySetValue(_requestsByURL, key, aRequest);
            request = aRequest;
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self performRequest:aRequest];
            });
            [aRequest release];
        }
	}

	return request;
}

- (void)cancelRequest:(RCImageStoreRequest *)theRequest withDelegate:(id<RCImageStoreDelegate>)theDelegate {
    if(CFSetContainsValue(_requests, theRequest)) {
        RCImageStoreInternalRequest *aRequest = (RCImageStoreInternalRequest *)theRequest;
        [aRequest removeDelegate:theDelegate];
    }
}

- (void)notifyDelegate:(RCImageStoreInternalRequest *)aRequest {
    RCImage *image = [aRequest userInfo];
    NSURL *theURL = [aRequest URL];
    void *key = (void *)[[theURL absoluteString] hash];
    CFDictionarySetValue(_cache, key, image);
    CFSetRemoveValue(_requests, aRequest);
    CFDictionaryRemoveValue(_requestsByURL, key);
    for (id <RCImageStoreDelegate> aDelegate in [aRequest delegates]) {
        [aDelegate imageStore:self didReceiveImage:image withURL:theURL];
	}
}

- (void)notifyFailureToDelegate:(RCImageStoreInternalRequest *)aRequest {
    void *key = (void *)[[[aRequest URL] absoluteString] hash];
    CFSetRemoveValue(_requests, aRequest);
    CFDictionaryRemoveValue(_requestsByURL, key);
    NSError *theError = [aRequest userInfo];
    for (id <RCImageStoreDelegate> aDelegate in [aRequest delegates]) {
        if ([aDelegate respondsToSelector:@selector(imageStore:failedWithURL:error:)]) {
            [aDelegate imageStore:self failedWithURL:[aRequest URL] error:theError];
        }
    }
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
    [RCURLRequest requestWithRequest:aRequest handler:^(NSData *data, NSURLResponse *response, NSError *error) {
        RCImage *theImage = nil;
        if (!error && (![self requiresOKResponse] || HTTP_RESPONSE_IS_OK(response))) {
            theImage = [[RCImage alloc] initWithData:data];
        }
        if (theImage) {
            theImage = [self prepareImage:theImage];
            [self cacheImage:theImage withData:data response:response forURL:theURL];
            [theRequest setUserInfo:theImage];
            [self notifyDelegate:theRequest];
            [theImage release];
        } else {
            [theRequest setUserInfo:error];
            [self notifyFailureToDelegate:theRequest];
        }
        [self postNotificationName:RCImageStoreDidFinishRequestNotification request:aRequest];
        CFSetRemoveValue(_networkRequests, theRequest);
    }];
}

- (void)startFetchingImageWithRequest:(RCImageStoreInternalRequest *)theRequest
{
    if (CFSetGetCount(_networkRequests) < kMaximumNetworkRequests) {
        CFSetAddValue(_networkRequests, theRequest);
        [self reallyStartFetchingImageWithRequest:theRequest];
    } else {
        int64_t delayInSeconds = 0.1;
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            [self startFetchingImageWithRequest:theRequest];
        });
    }
}

- (void)performRequest:(RCImageStoreInternalRequest *)theRequest {
    @autoreleasepool {
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
    NSUInteger theKey = [self cacheKeyForURL:theURL];
    RCImage *theImage = (RCImage *)CFDictionaryGetValue(_cache, (void *)theKey);
    if (!theImage) {
        RCURLCache *sharedCache = [RCURLCache sharedCache];
        NSData *theData = [sharedCache cachedDataForURL:theURL];
        if (theData) {
            theImage = [[RCImage alloc] initWithData:theData];
            if (theImage) {
                theImage = [self prepareImage:theImage];
                CFDictionarySetValue(_cache, (void *)theKey, theImage);
                [theImage autorelease];
            }
        }
    }
    return theImage;
}

- (void)cacheImage:(RCImage *)theImage withData:(NSData *)theData response:(NSURLResponse *)response forURL:(NSURL *)theURL
{
    if (!theImage) {
        theImage = [[[RCImage alloc] initWithData:theData] autorelease];
        if (!theImage) {
            return;
        }
    }
    NSUInteger theKey = [self cacheKeyForURL:theURL];
    CFDictionarySetValue(_cache, (void *)theKey, theImage);
    NSURLRequest *theRequest = [NSURLRequest requestWithURL:theURL];
    if (!response) {
        NSString *imageFormat = nil;
        CGImageSourceRef imageSource = CGImageSourceCreateWithData((CFDataRef)theData, NULL);
        if (imageSource) {
            if (CGImageSourceGetStatus(imageSource) == kCGImageStatusComplete) {
                CFStringRef imageType = CGImageSourceGetType(imageSource);
                if (imageType) {
                    imageFormat = [(NSString *)UTTypeCopyPreferredTagWithClass(imageType, kUTTagClassMIMEType) autorelease];
                }
            }
            CFRelease(imageSource);
        }
        if (imageFormat) {
            NSDictionary *headerFields = @{@"Content-Type": [@"image/" stringByAppendingString:imageFormat]};
            response = [[[NSHTTPURLResponse alloc] initWithURL:theURL
                                                    statusCode:200
                                                   HTTPVersion:@"HTTP/1.1"
                                                  headerFields:headerFields] autorelease];
        }
    }
    if (response) {
        [[RCURLCache sharedCache] storeResponse:response withData:theData forRequest:theRequest];
    }
}

- (NSUInteger)cacheKeyForURL:(NSURL *)theURL
{
    return [[theURL absoluteString] hash];
}

- (void)postNotificationName:(NSString *)theName request:(NSURLRequest *)theRequest
{
    NSNotification *aNotification = [NSNotification notificationWithName:theName object:theRequest];
    [[NSNotificationCenter defaultCenter] postNotification:aNotification];
}

- (void)didReceiveMemoryWarning:(NSNotification *)aNotification {
	/* Empty the cache from the main thread */
	CFDictionaryRemoveAllValues(_cache);
}

#pragma mark singleton boilerplate

+ (RCImageStore *)sharedStore {
    static RCImageStore *sharedStore = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        sharedStore = [[self alloc] init];
    });
    return sharedStore;
}

+ (void)cancelRequest:(RCImageStoreRequest *)theRequest withDelegate:(id<RCImageStoreDelegate>)theDelegate
{
    [[self sharedStore] cancelRequest:theRequest withDelegate:theDelegate];
}

+ (RCImageStoreRequest *)requestImageWithURL:(NSURL *)theURL delegate:(id<RCImageStoreDelegate>)theDelegate
{
    return [[self sharedStore] requestImageWithURL:theURL delegate:theDelegate];
}

+ (RCImageStoreRequest *)requestImageWithURLString:(NSString *)theURLString delegate:(id<RCImageStoreDelegate>)theDelegate
{
    return [[self sharedStore] requestImageWithURLString:theURLString delegate:theDelegate];
}


@end
