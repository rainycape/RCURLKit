//
//  RCURLRequest.h
//  RCURLKit
//
//  Created by Alberto García Hierro on 06/01/13.
//  Copyright (c) 2013 Rainy Cape S.L. See LICENSE file.
//

#import <Foundation/Foundation.h>

#define HTTP_RESPONSE_IS_OK(resp) ({ \
    NSUInteger statusCode = [(NSHTTPURLResponse *)resp statusCode]; \
    statusCode >= 200 && statusCode < 300; \
})

typedef NS_ENUM(NSInteger, RCURLRequestMethod) {
    RCURLRequestMethodGET,
    RCURLRequestMethodHEAD,
    RCURLRequestMethodPOST,
    RCURLRequestMethodPUT,
    RCURLRequestMethodDELETE,
    RCURLRequestMethodTRACE,
    RCURLRequestMethodOPTIONS,
    RCURLRequestMethodCONNECT,
};

typedef void (^RCURLRequestHandler)(NSData *data, NSURLResponse *response, NSError *error);
typedef NSURLRequest * (^RCURLRedirectHandler)(NSURLConnection *connection, NSURLRequest *request, NSURLResponse *response);

extern NSString * const RCURLRequestWillStartNotification;
extern NSString * const RCURLRequestDidStartNotification;
extern NSString * const RCURLRequestWillFinishNotification;
extern NSString * const RCURLRequestDidFinishNotification;

extern NSString * const RCURLRequestCancelledKey;
extern NSString * const RCURLRequestFailedKey;
extern NSString * const RCURLRequestErrorKey;

@protocol RCURLRequestDelegate;

@interface RCURLRequest : NSObject <NSURLConnectionDataDelegate>

@property(nonatomic, copy) RCURLRedirectHandler redirectHandler;
@property(nonatomic, retain, readonly) NSMutableURLRequest *request;
@property(nonatomic, retain) NSDictionary *userInfo;
@property(nonatomic) BOOL canCache;
@property(nonatomic, readonly, getter = isFinished) BOOL finished;
@property(nonatomic, assign) id<RCURLRequestDelegate> delegate;

- (void)start;
- (void)cancel;
- (void)await;

+ (RCURLRequest *)requestWithURL:(NSURL *)theURL handler:(RCURLRequestHandler)handler;
+ (RCURLRequest *)requestWithURL:(NSURL *)theURL data:(NSData *)theData handler:(RCURLRequestHandler)handler;
+ (RCURLRequest *)requestWithURL:(NSURL *)theURL data:(NSData *)theData
                          method:(NSString *)theMethod handler:(RCURLRequestHandler)handler;
+ (RCURLRequest *)requestWithURL:(NSURL *)theURL method:(NSString *)theMethod
                      parameters:(NSDictionary *)theParameters handler:(RCURLRequestHandler)handler;
+ (RCURLRequest *)requestWithRequest:(NSURLRequest *)theRequest handler:(RCURLRequestHandler)handler;

+ (RCURLRequest *)requestWithURL:(NSURL *)theURL
                         handler:(RCURLRequestHandler)handler startImmediately:(BOOL)start;
+ (RCURLRequest *)requestWithURL:(NSURL *)theURL data:(NSData *)theData
                         handler:(RCURLRequestHandler)handler startImmediately:(BOOL)start;
+ (RCURLRequest *)requestWithURL:(NSURL *)theURL data:(NSData *)theData method:(NSString *)theMethod
                         handler:(RCURLRequestHandler)handler startImmediately:(BOOL)start;
+ (RCURLRequest *)requestWithURL:(NSURL *)theURL method:(NSString *)theMethod
                      parameters:(NSDictionary *)theParameters handler:(RCURLRequestHandler)handler
                startImmediately:(BOOL)start;
+ (RCURLRequest *)requestWithRequest:(NSURLRequest *)theRequest
                             handler:(RCURLRequestHandler)handler startImmediately:(BOOL)start;

@end

@protocol RCURLRequestDelegate <NSObject>

- (void)request:(RCURLRequest *)request didReceiveResponse:(NSURLResponse *)response;
- (void)request:(RCURLRequest *)request didReceiveData:(NSData *)data;
- (void)requestDidFinishLoading:(RCURLRequest *)request;
- (void)request:(RCURLRequest *)request didFailWithError:(NSError *)error;

@end
