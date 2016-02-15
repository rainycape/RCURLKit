//
//  RCURLCache.h
//  RCURLKit
//
//  Created by Alberto García Hierro on 21/01/13.
//  Copyright (c) 2013 Rainy Cape S.L. See LICENSE file.
//

#import <Foundation/Foundation.h>

extern NSString *const RCURLCacheBeganClearingNotification;
extern NSString *const RCURLCacheFinishedClearingNotification;

typedef NS_ENUM(NSInteger, RCURLCacheDocumentType) {
    RCURLCacheDocumentTypeOther,
    RCURLCacheDocumentTypePage,
    RCURLCacheDocumentTypeImage,
    RCURLCacheDocumentTypeVideo,
};

@interface RCURLCache : NSURLCache {
}

- (BOOL)hasCachedResponseForURL:(NSURL *)theURL;
- (BOOL)hasCachedResponseForRequest:(NSURLRequest *)request;
- (NSCachedURLResponse *)cachedResponseForURL:(NSURL *)theURL;
- (NSData *)cachedDataForURL:(NSURL *)theURL;
- (void)storeCachedData:(NSData *)theData withURL:(NSURL *)theURL;
- (void)storeResponse:(NSURLResponse *)response
             withData:(NSData *)data
           forRequest:(NSURLRequest *)request;
- (void)deleteCachedResponseForRequest:(NSURLRequest *)aRequest;
- (void)diskUsage:(void (^)(NSDictionary *diskUsage))completion;

- (void)clear;
- (void)trimToSize:(unsigned long long)theSize;
- (void)trimToDate:(NSDate *)theDate;

+ (RCURLCache *)sharedCache;

@end
