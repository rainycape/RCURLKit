//
//  RCKVCache.h
//  RCURLKit
//
//  Created by Alberto García Hierro on 21/2/15.
//  Copyright (c) 2015 Rainy Cape S.L. All rights reserved.
//

#import <Foundation/Foundation.h>

@class RCURLCache;

@interface RCKVCache : NSObject

@property(nonatomic, strong, readonly) RCURLCache *cache;

- (instancetype)initWithURLCache:(RCURLCache *)cache;

- (void)storeData:(NSData *)theData forKey:(NSString *)theKey expiresIn:(NSTimeInterval)expiresIn;
- (NSData *)dataForKey:(NSString *)theKey;
- (void)removeDataForKey:(NSString *)theKey;

+ (RCKVCache *)sharedCache;

@end
