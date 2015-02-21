//
//  RCURLCache.m
//  RCURLKit
//
//  Created by Alberto García Hierro on 21/01/13.
//  Copyright (c) 2013 Rainy Cape S.L. See LICENSE file.
//

#import <CommonCrypto/CommonCrypto.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
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

#define RCCACHE_LOG(...)

#define kMaximumPendingLRUUpdates (100)

typedef struct {
    sqlite3 *db;
    sqlite3_stmt *load_stmt;
    sqlite3_stmt *has_data_stmt;
    sqlite3_stmt *load_data_stmt;
    sqlite3_stmt *store_stmt;
    sqlite3_stmt *delete_stmt;
} Database;

static Database *database_new(void)
{
    Database *db = malloc(sizeof(*db));
#if defined(__i386__) || defined(__amd64__)
    /* Simulator */
    NSString *dbPath = @"/tmp/rcurlcache.db";
#else
    /* Device */
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *dbPath = [documentsDirectory stringByAppendingPathComponent:@"rcurlcache.db"];
#endif
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:dbPath];
    sqlite3_open([dbPath UTF8String], &db->db);
    if (!exists) {
        sqlite3_exec(db->db, CREATE_SQL, NULL, NULL, NULL);
        sqlite3_exec(db->db, "CREATE INDEX dt_idx ON cache (dt); ", NULL, NULL, NULL);
        sqlite3_exec(db->db, "CREATE INDEX me_idx ON cache (me); ", NULL, NULL, NULL);
        sqlite3_exec(db->db, "CREATE INDEX me_lu_idx ON cache (me, lu); ", NULL, NULL, NULL);
    }
#define ENSURE_SQLITE_OK(x)                                                                        \
    do {                                                                                           \
        int retries = 0;                                                                           \
        while (1) {                                                                                \
            int ret = x;                                                                           \
            if (ret == SQLITE_BUSY && retries < 5) {                                               \
                retries++;                                                                         \
                if ([NSThread currentThread] != [NSThread mainThread]) {                           \
                    [NSThread sleepForTimeInterval:0.01];                                          \
                }                                                                                  \
                continue;                                                                          \
            }                                                                                      \
            if (ret != SQLITE_OK) {                                                                \
                NSLog(@"%s returned sqlite error %d", #x, ret);                                    \
            }                                                                                      \
            break;                                                                                 \
        }                                                                                          \
    } while (0)

    ENSURE_SQLITE_OK(sqlite3_exec(db->db, CONFIGURE_CACHE_SQL, NULL, NULL, NULL));
    ENSURE_SQLITE_OK(sqlite3_exec(db->db, "PRAGMA journal_mode=WAL;", NULL, NULL, NULL));
    ENSURE_SQLITE_OK(sqlite3_prepare_v2(db->db, LOAD_SQL, -1, &db->load_stmt, NULL));
    ENSURE_SQLITE_OK(sqlite3_prepare_v2(db->db, HAS_DATA_SQL, -1, &db->has_data_stmt, NULL));
    ENSURE_SQLITE_OK(sqlite3_prepare_v2(db->db, LOAD_DATA_SQL, -1, &db->load_data_stmt, NULL));
    ENSURE_SQLITE_OK(sqlite3_prepare_v2(db->db, STORE_SQL, -1, &db->store_stmt, NULL));
    ENSURE_SQLITE_OK(sqlite3_prepare_v2(db->db, DELETE_SQL, -1, &db->delete_stmt, NULL));
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

@property(nonatomic, strong) NSMutableDictionary *pendingLRUUpdates;

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
        _db = database_new();
        [self setPendingLRUUpdates:[NSMutableDictionary
                                       dictionaryWithCapacity:kMaximumPendingLRUUpdates]];
#if TARGET_OS_IPHONE
        NSNotificationCenter *defaultCenter = [NSNotificationCenter defaultCenter];
        [defaultCenter addObserver:self
                          selector:@selector(applicationWillResignActive:)
                              name:UIApplicationWillResignActiveNotification
                            object:nil];
#endif
    }

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    database_free(_db);
}

#pragma mark - Testing if cached data is available

- (BOOL)hasCachedResponseForURL:(NSURL *)theURL
{
    BOOL has = NO;
    BOOL shouldFree = NO;
    Database *db = [self databaseShouldFree:&shouldFree];
    sqlite3_bind_int64(db->has_data_stmt, 1, [self cacheKeyWithURL:theURL]);
    has = sqlite3_step(db->has_data_stmt) == SQLITE_ROW;
    sqlite3_reset(db->has_data_stmt);
    if (shouldFree) {
        database_free(db);
    }
    return has;
}

- (BOOL)hasCachedResponseForRequest:(NSURLRequest *)request
{
    return [self hasCachedResponseForURL:[request URL]];
}

#pragma mark - Retrieving data

- (NSCachedURLResponse *)cachedResponseForURL:(NSURL *)theURL
{
    NSCachedURLResponse *cachedResponse = nil;
    sqlite3_int64 key = [self cacheKeyWithURL:theURL];
    BOOL shouldFree = NO;
    Database *db = [self databaseShouldFree:&shouldFree];
    sqlite3_stmt *load_stmt = db->load_stmt;
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
        NSHTTPURLResponse *response = [NSKeyedUnarchiver unarchiveObjectWithData:theResponseData];
        cachedResponse = [[NSCachedURLResponse alloc] initWithResponse:response data:theData];
    } else {
        RCCACHE_LOG(@"Cache MISS for URL %@ (%lld)", theURL, (long long)key);
    }
    sqlite3_reset(load_stmt);
    if (cachedResponse) {
        [self updateLRUWithKey:key];
    }
    if (shouldFree) {
        database_free(db);
    }
    return cachedResponse;
}

- (NSCachedURLResponse *)cachedResponseForRequest:(NSURLRequest *)request
{
    return [self cachedResponseForURL:[request URL]];
}

- (NSData *)cachedDataForURL:(NSURL *)theURL
{
    NSData *theData = nil;
    sqlite3_int64 key = [self cacheKeyWithURL:theURL];
    BOOL shouldFree = NO;
    Database *db = [self databaseShouldFree:&shouldFree];
    sqlite3_stmt *load_data_stmt = db->load_data_stmt;
    sqlite3_bind_int64(load_data_stmt, 1, key);
    if (sqlite3_step(load_data_stmt) == SQLITE_ROW) {
        RCCACHE_LOG(@"Cache HIT for URL %@ (%lld)", theURL, (long long)key);
        const void *data = sqlite3_column_blob(load_data_stmt, 0);
        NSInteger dataSize = sqlite3_column_bytes(load_data_stmt, 0);
        theData = [NSData dataWithBytes:data length:dataSize];
    } else {
        RCCACHE_LOG(@"Cache MISS for URL %@ (%lld)", theURL, (long long)key);
    }
    sqlite3_reset(load_data_stmt);
    if (theData) {
        [self updateLRUWithKey:key];
    }
    if (shouldFree) {
        database_free(db);
    }
    return theData;
}

#pragma mark - Saving data

- (void)storeCachedResponse:(NSCachedURLResponse *)cachedResponse forRequest:(NSURLRequest *)request
{
    if (cachedResponse) {
        [self reallyStoreCachedResponse:cachedResponse forRequest:request];
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
    /* Check if we should relase the data */
    BOOL shouldFree = NO;
    Database *db = [self databaseShouldFree:&shouldFree];
    sqlite3_stmt *store_stmt = db->store_stmt;
    sqlite3_bind_int64(store_stmt, 1, [self cacheKeyWithURL:[request URL]]);
    sqlite3_bind_blob(store_stmt, 2, [theData bytes], (int)[theData length], SQLITE_STATIC);
    sqlite3_bind_blob(store_stmt, 3, [responseData bytes], (int)[responseData length],
                      SQLITE_STATIC);
    sqlite3_bind_int(store_stmt, 4, documentType);
    sqlite3_bind_int(store_stmt, 5, (int)[theData length]);
    sqlite3_bind_int64(store_stmt, 6, (sqlite3_int64)time(NULL));
    sqlite3_bind_null(store_stmt, 7);
    sqlite3_step(store_stmt);
    sqlite3_reset(store_stmt);
    if (shouldFree) {
        database_free(db);
    }
}

#pragma mark - Deleting data

- (void)deleteCachedResponseForRequest:(NSURLRequest *)request
{
    RCCACHE_LOG(@"Deleting response for %@", [request URL]);
    BOOL shouldFree = NO;
    Database *db = [self databaseShouldFree:&shouldFree];
    sqlite3_stmt *delete_stmt = db->delete_stmt;
    sqlite3_bind_int64(delete_stmt, 1, [self cacheKeyWithURL:[request URL]]);
    sqlite3_step(delete_stmt);
    sqlite3_reset(delete_stmt);
    if (shouldFree) {
        database_free(db);
    }
}

#pragma - Public functions for disk usage and clearing cache

- (NSDictionary *)diskUsage
{
    NSMutableDictionary *theDict = [NSMutableDictionary dictionary];
    sqlite3_stmt *count_stmt;
    BOOL shouldFree = NO;
    Database *db = [self databaseShouldFree:&shouldFree];
    sqlite3_prepare_v2(db->db, "SELECT SUM(s) FROM cache WHERE dt = ?", -1, &count_stmt, NULL);
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
    if (shouldFree) {
        database_free(db);
    }
    return theDict;
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
    BOOL shouldFree = NO;
    Database *db = [self databaseShouldFree:&shouldFree];
    sqlite3_prepare_v2(db->db, "SELECT SUM(s) FROM cache WHERE me IS NULL OR me < ?", -1,
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
        sqlite3_prepare_v2(db->db,
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
    if (shouldFree) {
        database_free(db);
    }
    return deletions;
}

- (NSArray *)entriesToDeleteForTrimmingToDate:(NSDate *)theDate
{
    NSMutableArray *deletions = [NSMutableArray array];
    sqlite3_int64 t = time(NULL);
    sqlite3_stmt *expired_stmt;
    BOOL shouldFree = NO;
    Database *db = [self databaseShouldFree:&shouldFree];
    sqlite3_prepare_v2(db->db, "SELECT SUM(s) FROM cache WHERE me IS NULL OR me < ? AND lu < ?", -1,
                       &expired_stmt, NULL);
    sqlite3_int64 expiry = [theDate timeIntervalSince1970];
    sqlite3_bind_int64(expired_stmt, 1, t);
    sqlite3_bind_int64(expired_stmt, 2, expiry);
    while (sqlite3_step(expired_stmt) == SQLITE_ROW) {
        sqlite3_int64 h = sqlite3_column_int64(expired_stmt, 0);
        [deletions addObject:[NSNumber numberWithLongLong:h]];
    }
    sqlite3_finalize(expired_stmt);
    if (shouldFree) {
        database_free(db);
    }
    return deletions;
}

#pragma mark - Private functions for trimming the database

- (void)deleteEntries:(NSArray *)theEntries completionHandler:(void (^)(void))completionHandler
{
    if ([theEntries count]) {
        sqlite3_stmt *delete_stmt;
        BOOL shouldFree = NO;
        Database *db = [self databaseShouldFree:&shouldFree];
        sqlite3_prepare_v2(db->db, "DELETE FROM cache WHERE h = ?", -1, &delete_stmt, NULL);
        for (NSNumber *aNumber in theEntries) {
            sqlite3_bind_int64(delete_stmt, 1, [aNumber longLongValue]);
            sqlite3_step(delete_stmt);
            sqlite3_reset(delete_stmt);
        }
        sqlite3_finalize(delete_stmt);
        if (shouldFree) {
            database_free(db);
        }
    }
    if (completionHandler) {
        dispatch_async(dispatch_get_main_queue(), completionHandler);
    }
}

- (void)trimToSize:(unsigned long long)theSize completionHandler:(void (^)(void))completionHandler
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSArray *deletions = [self entriesToDeleteForTrimmingToSize:theSize];
        [self deleteEntries:deletions completionHandler:completionHandler];
    });
}

- (void)trimToDate:(NSDate *)theDate completionHandler:(void (^)(void))completionHandler
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSArray *deletions = [self entriesToDeleteForTrimmingToDate:theDate];
        [self deleteEntries:deletions completionHandler:completionHandler];
    });
}

#pragma mark - Utility functions

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
        [self flushPendingLURUpdates];
    }
}

- (void)flushPendingLURUpdates
{
    NSMutableDictionary *theUpdates = nil;
    @synchronized(self)
    {
        theUpdates = [pendingLRUUpdates_ copy];
        [pendingLRUUpdates_ removeAllObjects];
    }
    if (theUpdates.count > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            BOOL shouldFree = NO;
            Database *db = [self databaseShouldFree:&shouldFree];
            sqlite3_stmt *update_lru_stmt;
            sqlite3_prepare_v2(db->db, UPDATE_LRU_SQL, -1, &update_lru_stmt, NULL);
            for (NSNumber *aKey in theUpdates) {
                NSNumber *aValue = [theUpdates objectForKey:aKey];
                sqlite3_bind_int64(update_lru_stmt, 1, (sqlite3_int64)[aValue longLongValue]);
                sqlite3_bind_int64(update_lru_stmt, 2, (sqlite3_int64)[aKey longLongValue]);
                sqlite3_step(update_lru_stmt);
                sqlite3_reset(update_lru_stmt);
            }
            sqlite3_finalize(update_lru_stmt);
            if (shouldFree) {
                database_free(db);
            }
        });
    }
}

- (Database *)databaseShouldFree:(BOOL *)shouldFree
{
    if ([NSThread isMainThread]) {
        *shouldFree = NO;
        return _db;
    }
    *shouldFree = YES;
    return database_new();
}

#pragma mark - NSNotification handlers

- (void)applicationWillResignActive:(NSNotification *)aNotification
{
    [self flushPendingLURUpdates];
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
