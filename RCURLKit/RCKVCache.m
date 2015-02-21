//
//  RCKVCache.m
//  RCURLKit
//
//  Created by Alberto García Hierro on 21/2/15.
//  Copyright (c) 2015 Rainy Cape S.L. All rights reserved.
//

#import "RCURLCache.h"
#import "RCURLRequest.h"

#import "RCKVCache.h"

static NSString *const kKVCacheScheme = @"kv";
static NSString *const kKVCacheExpirationHeader = @"X-RCURLCache-Expiration";

@interface RCURLRequest (Private)

+ (NSString *)URLEncodedString:(NSString *)theString;

@end

@interface RCKVCache ()

@property(nonatomic, strong) RCURLCache *cache;

@end

@implementation RCKVCache

- (instancetype)initWithURLCache:(RCURLCache *)cache
{
    if ((self = [super init])) {
        self.cache = cache;
    }
    return self;
}

#pragma mark - Public API

- (void)storeData:(NSData *)theData forKey:(NSString *)theKey expiresIn:(NSTimeInterval)expiresIn
{
    NSURL *cacheURL = [self cacheURLWithKey:theKey];
    NSURLRequest *theRequest = [[NSURLRequest alloc] initWithURL:cacheURL];
    NSDictionary *headerFields = nil;
    if (expiresIn > 0) {
        NSString *expiration =
            @([[NSDate dateWithTimeIntervalSinceNow:expiresIn] timeIntervalSince1970]).stringValue;
        headerFields = @{
            kKVCacheExpirationHeader : expiration,
        };
    }
    NSURLResponse *theResponse = [[NSHTTPURLResponse alloc] initWithURL:cacheURL
                                                             statusCode:200
                                                            HTTPVersion:@"HTTP/1.1"
                                                           headerFields:headerFields];
    [self.cache storeResponse:theResponse withData:theData forRequest:theRequest];
}

- (NSData *)dataForKey:(NSString *)theKey
{
    NSCachedURLResponse *response = [self.cache cachedResponseForURL:[self cacheURLWithKey:theKey]];
    if ([response.response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response.response;
        NSDictionary *theHeaders = [httpResponse allHeaderFields];
        NSString *theExpiration = [theHeaders objectForKey:kKVCacheExpirationHeader];
        if ([theExpiration isKindOfClass:[NSString class]]) {
            if ([theExpiration doubleValue] < [[NSDate date] timeIntervalSince1970]) {
                // Expired entry
                [self removeDataForKey:theKey];
                response = nil;
            }
        }
    }
    return response.data;
}

- (void)removeDataForKey:(NSString *)theKey
{
    NSURL *cacheURL = [self cacheURLWithKey:theKey];
    NSURLRequest *theRequest = [[NSURLRequest alloc] initWithURL:cacheURL];
    [self.cache storeCachedResponse:nil forRequest:theRequest];
}

#pragma mark - Internal methods

- (NSURL *)cacheURLWithKey:(NSString *)theKey
{
    NSString *URLString = [NSString
        stringWithFormat:@"%@://key/%@", kKVCacheScheme, [RCURLRequest URLEncodedString:theKey]];
    return [NSURL URLWithString:URLString];
}

#pragma mark - Public class methods

+ (RCKVCache *)sharedCache
{
    static RCKVCache *sharedCache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedCache = [[RCKVCache alloc] initWithURLCache:[RCURLCache sharedCache]];
    });
    return sharedCache;
}

@end
