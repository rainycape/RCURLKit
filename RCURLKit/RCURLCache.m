//
//  RCURLCache.m
//  RCURLKit
//
//  Created by Alberto García Hierro on 21/01/13.
//  Copyright (c) 2013 Rainy Cape S.L. See LICENSE file.
//

#import <CommonCrypto/CommonCrypto.h>
#import <Foundation/Foundation.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif

#import <sqlite3.h>

#import "RCURLCache.h"

/*
    h: url hash
    d: data
    rd: response data (serialized NSURLResponse)
    dt: document type
    s: size
    lu: last used timestamp
    me: min expiration timestamp, used for offline mode
 */

#define CREATE_SQL                                                                                 \
    "CREATE TABLE cache "                                                                          \
    "(h UNSIGNED INTEGER PRIMARY KEY UNIQUE, "                                                     \
    "d BLOB, "                                                                                     \
    "rd BLOB, "                                                                                    \
    "dt UNSIGNED INTEGER, "                                                                        \
    "s UNSIGNED INTEGER, "                                                                         \
    "lu UNSIGNED INTEGER, "                                                                        \
    "me UNSIGNED INTEGER)"

#define LOAD_SQL                                                                                   \
    "SELECT d, rd FROM "                                                                           \
    "cache WHERE h = ?"

#define LOAD_DATA_SQL                                                                              \
    "SELECT d FROM "                                                                               \
    "cache WHERE h = ?"

#define HAS_DATA_SQL                                                                               \
    "SELECT 1 FROM "                                                                               \
    "cache WHERE h = ?"

#define STORE_SQL                                                                                  \
    "INSERT OR REPLACE INTO cache "                                                                \
    "(h, d, rd, dt, s, lu, me) VALUES (?, ?, ?, ?, ?, ?, ?)"

#define DELETE_SQL "DELETE FROM cache WHERE h = ?"

#define UPDATE_LRU_SQL "UPDATE cache SET lu = ? WHERE h = ?"

#define CONFIGURE_CACHE_SQL "PRAGMA CACHE_SIZE=20"

#ifdef RCURLCACHE_DEBUG
#define RCCACHE_LOG(...) NSLog(__VA_ARGS__)
#else
#define RCCACHE_LOG(...)
#endif

#define kMaximumPendingLRUUpdates (100)

typedef struct {
    sqlite3 *db;
    sqlite3_stmt *load_stmt;
    sqlite3_stmt *has_data_stmt;
    sqlite3_stmt *load_data_stmt;
    sqlite3_stmt *store_stmt;
    sqlite3_stmt *delete_stmt;
} Database;

static Database *database_new(NSString *dbPath)
{
    Database *db = malloc(sizeof(*db));
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:dbPath];
    int ret = sqlite3_open([dbPath UTF8String], &db->db);
    if (ret != SQLITE_OK) {
        NSLog(@"error opening database at %@: %s", dbPath, sqlite3_errstr(ret));
        free(db);
        return NULL;
    }
    if (!exists) {
        sqlite3_exec(db->db, CREATE_SQL, NULL, NULL, NULL);
        sqlite3_exec(db->db, "CREATE INDEX dt_idx ON cache (dt); ", NULL, NULL, NULL);
        sqlite3_exec(db->db, "CREATE INDEX me_idx ON cache (me); ", NULL, NULL, NULL);
        sqlite3_exec(db->db, "CREATE INDEX me_lu_idx ON cache (me, lu); ", NULL, NULL, NULL);
    }
    sqlite3_exec(db->db, CONFIGURE_CACHE_SQL, NULL, NULL, NULL);
    sqlite3_exec(db->db, "PRAGMA journal_mode=WAL;", NULL, NULL, NULL);
    sqlite3_prepare_v2(db->db, LOAD_SQL, -1, &db->load_stmt, NULL);
    sqlite3_prepare_v2(db->db, HAS_DATA_SQL, -1, &db->has_data_stmt, NULL);
    sqlite3_prepare_v2(db->db, LOAD_DATA_SQL, -1, &db->load_data_stmt, NULL);
    sqlite3_prepare_v2(db->db, STORE_SQL, -1, &db->store_stmt, NULL);
    sqlite3_prepare_v2(db->db, DELETE_SQL, -1, &db->delete_stmt, NULL);
    return db;
}

static void database_free(Database *db)
{
    sqlite3_finalize(db->load_stmt);
    sqlite3_finalize(db->has_data_stmt);
    sqlite3_finalize(db->load_data_stmt);
    sqlite3_finalize(db->store_stmt);
    sqlite3_finalize(db->delete_stmt);
    sqlite3_close(db->db);
    free(db);
}

NSString *const RCURLCacheBeganClearingNotification = @"RCURLCacheBeganClearingNotification";
NSString *const RCURLCacheFinishedClearingNotification = @"RCURLCacheFinishedClearingNotification";

@interface RCURLCache ()

@property(NS_NONATOMIC_IOSONLY, strong) NSMutableDictionary *pendingLRUUpdates;
@property(NS_NONATOMIC_IOSONLY, strong) dispatch_queue_t queue;

@end

@implementation RCURLCache {
    Database *_db;
}

@synthesize pendingLRUUpdates = pendingLRUUpdates_;

- (id)initWithMemoryCapacity:(NSUInteger)memoryCapacity
                diskCapacity:(NSUInteger)diskCapacity
                    diskPath:(NSString *)path
{
    if ((self
         = [super initWithMemoryCapacity:memoryCapacity diskCapacity:diskCapacity diskPath:path])) {
        self.queue = dispatch_queue_create("RCURLCache", DISPATCH_QUEUE_SERIAL);
        [self open];
        self.pendingLRUUpdates =
            [NSMutableDictionary dictionaryWithCapacity:kMaximumPendingLRUUpdates];
        NSNotificationCenter *defaultCenter = [NSNotificationCenter defaultCenter];
#if TARGET_OS_IPHONE
        [defaultCenter addObserver:self
                          selector:@selector(applicationWillResignActive:)
                              name:UIApplicationWillResignActiveNotification
                            object:nil];
        [defaultCenter addObserver:self
                          selector:@selector(applicationWillTerminate:)
                              name:UIApplicationWillTerminateNotification
                            object:nil];
#else
        [defaultCenter addObserver:self
                          selector:@selector(applicationWillResignActive:)
                              name:NSApplicationWillResignActiveNotification
                            object:nil];
        [defaultCenter addObserver:self
                          selector:@selector(applicationWillTerminate:)
                              name:NSApplicationWillTerminateNotification
                            object:nil];
#endif
    }

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self close];
}

#pragma mark - Database path

- (NSString *)databasePath
{
    NSString *cacheFilename = @"rcurlcache.db";
#if TARGET_OS_IPHONE && (defined(__i386__) || defined(__amd64__))
    /* Simulator */
    return [@"/tmp" stringByAppendingPathComponent:cacheFilename];
#else
    /* Device or OS X */
    NSString *cachesDirectory =
        [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
#if !TARGET_OS_IPHONE
    // Only do this for OS X to keep database in the same location than
    // it was on iOS.
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    cachesDirectory = [cachesDirectory stringByAppendingPathComponent:bundleIdentifier];
#endif
    return [cachesDirectory stringByAppendingPathComponent:cacheFilename];
#endif
}

#pragma mark - Testing if cached data is available

- (BOOL)hasCachedResponseForURL:(NSURL *)theURL
{
    if (!_db) {
        return NO;
    }
    __block BOOL has = NO;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, self.queue, ^{
        sqlite3_reset(_db->has_data_stmt);
        sqlite3_bind_int64(_db->has_data_stmt, 1, [self cacheKeyWithURL:theURL]);
        has = sqlite3_step(_db->has_data_stmt) == SQLITE_ROW;
    });
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return has;
}

- (BOOL)hasCachedResponseForRequest:(NSURLRequest *)request
{
    return [self hasCachedResponseForURL:[request URL]];
}

#pragma mark - Retrieving data

- (NSCachedURLResponse *)cachedResponseForURL:(NSURL *)theURL
{
    if (!_db) {
        return nil;
    }
    __block NSCachedURLResponse *cachedResponse = nil;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, self.queue, ^{
        sqlite3_int64 key = [self cacheKeyWithURL:theURL];
        sqlite3_stmt *load_stmt = _db->load_stmt;
        sqlite3_reset(load_stmt);
        sqlite3_bind_int64(load_stmt, 1, key);
        if (sqlite3_step(load_stmt) == SQLITE_ROW) {
            RCCACHE_LOG(@"Cache HIT for URL %@ (%lld)", theURL, (long long)key);
            const void *data = sqlite3_column_blob(load_stmt, 0);
            NSInteger dataSize = sqlite3_column_bytes(load_stmt, 0);
            const void *responseData = sqlite3_column_blob(load_stmt, 1);
            NSInteger responseDataSize = sqlite3_column_bytes(load_stmt, 1);
            NSData *theData = [NSData dataWithBytes:data length:dataSize];
            NSData *theResponseData = [NSData dataWithBytesNoCopy:(void *)responseData
                                                           length:responseDataSize
                                                     freeWhenDone:NO];
            NSHTTPURLResponse *response =
                [NSKeyedUnarchiver unarchiveObjectWithData:theResponseData];
            cachedResponse = [[NSCachedURLResponse alloc] initWithResponse:response data:theData];
        } else {
            RCCACHE_LOG(@"Cache MISS for URL %@ (%lld)", theURL, (long long)key);
        }
        if (cachedResponse) {
            [self updateLRUWithKey:key];
        }
    });
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return cachedResponse;
}

- (NSCachedURLResponse *)cachedResponseForRequest:(NSURLRequest *)request
{
    return [self cachedResponseForURL:[request URL]];
}

- (NSData *)cachedDataForURL:(NSURL *)theURL
{
    if (!_db) {
        return nil;
    }
    __block NSData *theData = nil;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, self.queue, ^{
        sqlite3_int64 key = [self cacheKeyWithURL:theURL];
        sqlite3_stmt *load_data_stmt = _db->load_data_stmt;
        sqlite3_reset(load_data_stmt);
        sqlite3_bind_int64(load_data_stmt, 1, key);
        if (sqlite3_step(load_data_stmt) == SQLITE_ROW) {
            RCCACHE_LOG(@"Cache HIT for URL %@ (%lld)", theURL, (long long)key);
            const void *data = sqlite3_column_blob(load_data_stmt, 0);
            NSInteger dataSize = sqlite3_column_bytes(load_data_stmt, 0);
            theData = [NSData dataWithBytes:data length:dataSize];
        } else {
            RCCACHE_LOG(@"Cache MISS for URL %@ (%lld)", theURL, (long long)key);
        }
        if (theData) {
            [self updateLRUWithKey:key];
        }
    });
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return theData;
}

#pragma mark - Saving data

- (void)storeCachedResponse:(NSCachedURLResponse *)cachedResponse forRequest:(NSURLRequest *)request
{
    if (!_db) {
        return;
    }
    if (cachedResponse) {
        dispatch_async(self.queue,
                       ^{ [self reallyStoreCachedResponse:cachedResponse forRequest:request]; });
    } else {
        [self deleteCachedResponseForRequest:request];
    }
}

- (void)storeCachedData:(NSData *)theData withURL:(NSURL *)theURL
{
    NSURLRequest *theRequest = [[NSURLRequest alloc] initWithURL:theURL];
    NSURLResponse *theResponse = [[NSHTTPURLResponse alloc] initWithURL:theURL
                                                             statusCode:200
                                                            HTTPVersion:@"HTTP/1.1"
                                                           headerFields:nil];
    [self storeResponse:theResponse withData:theData forRequest:theRequest];
}

- (void)storeResponse:(NSURLResponse *)response
             withData:(NSData *)data
           forRequest:(NSURLRequest *)request
{
    if (!_db) {
        return;
    }
    NSCachedURLResponse *cachedResponse =
        [[NSCachedURLResponse alloc] initWithResponse:response data:data];
    [self storeCachedResponse:cachedResponse forRequest:request];
}

- (void)reallyStoreCachedResponse:(NSCachedURLResponse *)cachedResponse
                       forRequest:(NSURLRequest *)request
{
    RCCACHE_LOG(@"Caching response for %@", [request URL]);
    RCURLCacheDocumentType documentType = RCURLCacheDocumentTypeOther;
    NSURLResponse *theResponse = [cachedResponse response];
    NSString *contentType = nil;
    if ([theResponse isKindOfClass:[NSHTTPURLResponse class]]) {
        contentType =
            [[(NSHTTPURLResponse *)theResponse allHeaderFields] objectForKey:@"Content-Type"];
    }
    if ([contentType hasPrefix:@"image/"]) {
        documentType = RCURLCacheDocumentTypeImage;
    } else if ([contentType hasPrefix:@"video/"]) {
        documentType = RCURLCacheDocumentTypeVideo;
    } else if ([contentType rangeOfString:@"html"].location != NSNotFound) {
        documentType = RCURLCacheDocumentTypePage;
    }
    NSData *responseData = [NSKeyedArchiver archivedDataWithRootObject:theResponse];
    NSData *theData = [cachedResponse data];
    sqlite3_stmt *store_stmt = _db->store_stmt;
    sqlite3_reset(store_stmt);
    sqlite3_bind_int64(store_stmt, 1, [self cacheKeyWithURL:[request URL]]);
    sqlite3_bind_blob(store_stmt, 2, [theData bytes], (int)[theData length], SQLITE_STATIC);
    sqlite3_bind_blob(store_stmt, 3, [responseData bytes], (int)[responseData length],
                      SQLITE_STATIC);
    sqlite3_bind_int(store_stmt, 4, documentType);
    sqlite3_bind_int(store_stmt, 5, (int)[theData length]);
    sqlite3_bind_int64(store_stmt, 6, (sqlite3_int64)time(NULL));
    sqlite3_bind_null(store_stmt, 7);
    int retries = 0;
    while (1) {
        int ret = sqlite3_step(store_stmt);
        if ((ret == SQLITE_BUSY) && retries < 10) {
            retries++;
            if ([NSThread currentThread] != [NSThread mainThread]) {
                [NSThread sleepForTimeInterval:0.01];
            }
            continue;
        }
        if (ret != SQLITE_DONE) {
            NSLog(@"Error caching %@: %d", request.URL, ret);
        }
        break;
    }
    sqlite3_reset(store_stmt);
}

#pragma mark - Deleting data

- (void)deleteCachedResponseForRequest:(NSURLRequest *)request
{
    if (!_db) {
        return;
    }
    RCCACHE_LOG(@"Deleting response for %@", [request URL]);
    dispatch_async(self.queue, ^{
        sqlite3_reset(_db->delete_stmt);
        sqlite3_bind_int64(_db->delete_stmt, 1, [self cacheKeyWithURL:[request URL]]);
        sqlite3_step(_db->delete_stmt);
    });
}

#pragma - Public functions for disk usage and clearing cache

- (void)diskUsage:(void (^)(NSDictionary *diskUsage))completion
{
    if (!completion) {
        return;
    }
    if (!_db) {
        completion(nil);
        return;
    }
    dispatch_async(self.queue, ^{
        NSMutableDictionary *theDict = [NSMutableDictionary dictionary];
        sqlite3_stmt *count_stmt;
        sqlite3_prepare_v2(_db->db, "SELECT SUM(s) FROM cache WHERE dt = ?", -1, &count_stmt, NULL);
        for (int ii = RCURLCacheDocumentTypeOther; ii <= RCURLCacheDocumentTypeVideo; ++ii) {
            sqlite3_bind_int(count_stmt, 1, ii);
            if (sqlite3_step(count_stmt) == SQLITE_ROW) {
                int bytes = sqlite3_column_int(count_stmt, 0);
                if (bytes > 0) {
                    [theDict setObject:[NSNumber numberWithInt:bytes]
                                forKey:[NSNumber numberWithInt:ii]];
                }
            }
            sqlite3_reset(count_stmt);
        }
        sqlite3_finalize(count_stmt);
        completion(theDict);
    });
}

- (void)clear
{
    [[NSNotificationCenter defaultCenter] postNotificationName:RCURLCacheBeganClearingNotification
                                                        object:self];
    [self trimToSize:0
        completionHandler:^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:RCURLCacheFinishedClearingNotification
                              object:self];
        }];
}

- (void)trimToSize:(unsigned long long)theSize
{
    [self trimToSize:theSize completionHandler:nil];
}

- (void)trimToDate:(NSDate *)theDate
{
    [self trimToDate:theDate completionHandler:nil];
}

- (NSArray *)entriesToDeleteForTrimmingToSize:(unsigned long long)theSize
{
    sqlite3_int64 t = time(NULL);
    sqlite3_stmt *size_stmt;
    sqlite3_prepare_v2(_db->db, "SELECT SUM(s) FROM cache WHERE me IS NULL OR me < ?", -1,
                       &size_stmt, NULL);
    sqlite3_int64 currentSize = 0;
    sqlite3_bind_int64(size_stmt, 1, t);
    NSMutableArray *deletions = nil;
    if (sqlite3_step(size_stmt) == SQLITE_ROW) {
        currentSize = sqlite3_column_int64(size_stmt, 0);
    }
    sqlite3_finalize(size_stmt);
    if (currentSize > theSize) {
        deletions = [NSMutableArray array];
        sqlite3_stmt *query_stmt;
        sqlite3_prepare_v2(_db->db,
                           "SELECT h, s FROM cache WHERE me IS NULL OR me < ? ORDER BY lu DESC", -1,
                           &query_stmt, NULL);
        sqlite3_bind_int64(query_stmt, 1, t);
        while (sqlite3_step(query_stmt) == SQLITE_ROW && currentSize > theSize) {
            sqlite3_int64 h = sqlite3_column_int64(query_stmt, 0);
            [deletions addObject:[NSNumber numberWithLongLong:h]];
            int size = sqlite3_column_int(query_stmt, 1);
            currentSize -= size;
        }
        sqlite3_finalize(query_stmt);
    }
    return deletions;
}

- (NSArray *)entriesToDeleteForTrimmingToDate:(NSDate *)theDate
{
    NSMutableArray *deletions = [NSMutableArray array];
    sqlite3_int64 t = time(NULL);
    sqlite3_stmt *expired_stmt;
    sqlite3_prepare_v2(_db->db, "SELECT SUM(s) FROM cache WHERE me IS NULL OR me < ? AND lu < ?",
                       -1, &expired_stmt, NULL);
    sqlite3_int64 expiry = [theDate timeIntervalSince1970];
    sqlite3_bind_int64(expired_stmt, 1, t);
    sqlite3_bind_int64(expired_stmt, 2, expiry);
    while (sqlite3_step(expired_stmt) == SQLITE_ROW) {
        sqlite3_int64 h = sqlite3_column_int64(expired_stmt, 0);
        [deletions addObject:[NSNumber numberWithLongLong:h]];
    }
    sqlite3_finalize(expired_stmt);
    return deletions;
}

#pragma mark - Private functions for trimming the database

- (void)deleteEntries:(NSArray *)theEntries completionHandler:(void (^)(void))completionHandler
{
    if ([theEntries count]) {
        sqlite3_stmt *delete_stmt;
        sqlite3_prepare_v2(_db->db, "DELETE FROM cache WHERE h = ?", -1, &delete_stmt, NULL);
        for (NSNumber *aNumber in theEntries) {
            sqlite3_bind_int64(delete_stmt, 1, [aNumber longLongValue]);
            sqlite3_step(delete_stmt);
            sqlite3_reset(delete_stmt);
        }
        sqlite3_finalize(delete_stmt);
    }
    if (completionHandler) {
        dispatch_async(dispatch_get_main_queue(), completionHandler);
    }
}

- (void)trimToSize:(unsigned long long)theSize completionHandler:(void (^)(void))completionHandler
{
    if (!_db) {
        if (completionHandler) {
            completionHandler();
        }
        return;
    }
    dispatch_async(self.queue, ^{
        NSArray *deletions = [self entriesToDeleteForTrimmingToSize:theSize];
        [self deleteEntries:deletions completionHandler:completionHandler];
        [self vacuum];
    });
}

- (void)trimToDate:(NSDate *)theDate completionHandler:(void (^)(void))completionHandler
{
    if (!_db) {
        if (completionHandler) {
            completionHandler();
        }
        return;
    }
    dispatch_async(self.queue, ^{
        NSArray *deletions = [self entriesToDeleteForTrimmingToDate:theDate];
        [self deleteEntries:deletions completionHandler:completionHandler];
        [self vacuum];
    });
}

#pragma mark - Utility functions

- (void)vacuum
{
    if (_db && _db->db) {
        sqlite3 *db = _db->db;
        dispatch_async(self.queue, ^{ sqlite3_exec(db, "VACUUM", NULL, NULL, NULL); });
    }
}

- (sqlite3_int64)cacheKeyWithURL:(NSURL *)theURL
{
    return hash64(theURL.absoluteString);
}

- (void)updateLRUWithKey:(sqlite3_int64)hash
{
    time_t now = time(NULL);
    NSNumber *theHash = [NSNumber numberWithLongLong:hash];
    NSNumber *theValue = [NSNumber numberWithLongLong:now];
    NSUInteger count = 0;
    @synchronized(self)
    {
        [pendingLRUUpdates_ setObject:theValue forKey:theHash];
        count = [pendingLRUUpdates_ count];
    }
    if (count >= kMaximumPendingLRUUpdates) {
        [self flushPendingLURUpdatesWithCompletion:nil];
    }
}

- (void)flushPendingLURUpdatesWithCompletion:(void (^)())completion
{
    if (!_db) {
        if (completion) {
            completion();
        }
        return;
    }
    NSMutableDictionary *theUpdates = nil;
    @synchronized(self)
    {
        theUpdates = [pendingLRUUpdates_ copy];
        [pendingLRUUpdates_ removeAllObjects];
    }
    if (theUpdates.count > 0) {
        dispatch_async(self.queue, ^{
            sqlite3_stmt *update_lru_stmt;
            sqlite3_prepare_v2(_db->db, UPDATE_LRU_SQL, -1, &update_lru_stmt, NULL);
            for (NSNumber *aKey in theUpdates) {
                NSNumber *aValue = [theUpdates objectForKey:aKey];
                sqlite3_bind_int64(update_lru_stmt, 1, (sqlite3_int64)[aValue longLongValue]);
                sqlite3_bind_int64(update_lru_stmt, 2, (sqlite3_int64)[aKey longLongValue]);
                sqlite3_step(update_lru_stmt);
                sqlite3_reset(update_lru_stmt);
            }
            sqlite3_finalize(update_lru_stmt);
            if (completion) {
                completion();
            }
        });
    }
}

#pragma mark - Opening and closing

- (BOOL)open
{
    if (!_db) {
        NSString *thePath = [self databasePath];
        _db = database_new(thePath);
    }
    return _db != NULL;
}

- (void)close
{
    if (_db) {
        database_free(_db);
        _db = NULL;
    }
}

#pragma mark - NSNotification handlers

- (void)applicationWillResignActive:(NSNotification *)aNotification
{
    [self flushPendingLURUpdatesWithCompletion:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    // Don't flush pending LRU updates here, since we'll probably
    // have no time to flush and then close, hence the WAL won't
    // be cleared.
    [self close];
}

#pragma mark - Singleton

+ (RCURLCache *)sharedCache
{
    static dispatch_once_t once;
    static RCURLCache *sharedCache;
    dispatch_once(&once, ^{ sharedCache = [[self alloc] init]; });
    return sharedCache;
}

#pragma mark - Hashing

static inline __attribute__((always_inline)) sqlite3_int64 hash64(NSString *input)
{
    unsigned char buf[CC_MD5_DIGEST_LENGTH];
    const char *str = [input UTF8String];
    CC_MD5(str, (CC_LONG)strlen(str), buf);
    uint64_t data[2];
    memcpy(data, buf, sizeof(buf));
    buf[0] ^= buf[1];
    sqlite3_int64 ret;
    memcpy(&ret, buf, sizeof(ret));
    return ret;
}
@end
