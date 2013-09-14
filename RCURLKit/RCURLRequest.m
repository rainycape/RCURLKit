//
//  RCURLRequest.h.m
//  RCURLKit
//
//  Created by Alberto García Hierro on 06/01/13.
//  Copyright (c) 2013 Rainy Cape S.L. See LICENSE file.
//

#import "RCURLRequest.h"

NSString * const RCURLRequestWillStartNotification = @"RCURLRequestWillStartNotification";
NSString * const RCURLRequestDidStartNotification = @"RCURLRequestDidStartNotification";
NSString * const RCURLRequestWillFinishNotification = @"RCURLRequestWillFinishNotification";
NSString * const RCURLRequestDidFinishNotification = @"RCURLRequestDidFinishNotification";

NSString * const RCURLRequestCancelledKey = @"Cancelled";
NSString * const RCURLRequestFailedKey = @"Failed";
NSString * const RCURLRequestErrorKey = @"Error";

@interface RCURLRequest ()

@property(nonatomic, copy) RCURLRequestHandler handler;
@property(nonatomic, retain, readwrite) NSMutableURLRequest *request;
@property(nonatomic, readwrite, getter = isFinished) BOOL finished;
@property(nonatomic, retain) NSURLConnection *connection;
@property(nonatomic, retain) NSURLResponse *response;
@property(nonatomic, retain) NSMutableData *data;
@property(nonatomic, getter = isWaiting) BOOL waiting;

@end

@implementation RCURLRequest

- (id)init
{
    if ((self = [super init])) {
        [self setData:[NSMutableData data]];
    }
    return self;
}

- (void)dealloc
{
    [_handler release];
    [_redirectHandler release];
    [_request release];
    [_connection release];
    [_response release];
    [_data release];
    [_userInfo release];
    [super dealloc];
}

- (void)start
{
    if (![self connection]) {
        [self requestWillStart];
        NSURLConnection *theConnection = [[NSURLConnection alloc] initWithRequest:[self request]
                                                                         delegate:self
                                                                 startImmediately:NO];
        [self setConnection:theConnection];
        [theConnection start];
        [theConnection release];
        [self requestDidStart];
    }
}

- (void)cancel
{
    if ([self connection]) {
        [self requestWillFinishCancelled:YES failed:NO error:nil];
        [_connection cancel];
        [self requestDidFinishCancelled:YES failed:NO error:nil];
        [self setConnection:nil];
    }
}

- (void)await
{
    [self setWaiting:YES];
    [[NSRunLoop currentRunLoop] run];
}

- (void)setFinished:(BOOL)finished
{
    _finished = finished;
    if (finished && [self isWaiting]) {
        [self setWaiting:NO];
        CFRunLoopStop(CFRunLoopGetCurrent());
    }
}

#pragma mark Helpers for notifications

- (void)requestWillStart
{
    [[NSNotificationCenter defaultCenter] postNotificationName:RCURLRequestWillStartNotification
                                                        object:self];
}

- (void)requestDidStart
{
    [[NSNotificationCenter defaultCenter] postNotificationName:RCURLRequestDidStartNotification
                                                        object:self];
}

- (NSDictionary *)notificationUserInfoWithCancelled:(BOOL)cancelled failed:(BOOL)failed error:(NSError *)error
{
    return @{
        RCURLRequestCancelledKey: @(cancelled),
        RCURLRequestFailedKey: @(failed),
        RCURLRequestErrorKey: error ? error : [NSNull null],
    };
}

- (void)requestWillFinishCancelled:(BOOL)cancelled failed:(BOOL)failed error:(NSError *)error
{
    NSDictionary *userInfo = [self notificationUserInfoWithCancelled:cancelled failed:failed error:error];
    [[NSNotificationCenter defaultCenter] postNotificationName:RCURLRequestWillFinishNotification
                                                        object:self
                                                      userInfo:userInfo];
}

- (void)requestDidFinishCancelled:(BOOL)cancelled failed:(BOOL)failed error:(NSError *)error
{
    NSDictionary *userInfo = [self notificationUserInfoWithCancelled:cancelled failed:failed error:error];
    [[NSNotificationCenter defaultCenter] postNotificationName:RCURLRequestDidFinishNotification
                                                        object:self
                                                      userInfo:userInfo];
    [self setFinished:YES];
}

#pragma mark NSURLConnectionDataDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    [self setResponse:response];
    [[self data] setLength:0];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    [[self data] appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    if ([self handler]) {
        [self requestWillFinishCancelled:NO failed:NO error:nil];
        [self handler]([self data], [self response], nil);
        [self requestDidFinishCancelled:NO failed:NO error:nil];
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    if ([self handler]) {
        [self requestWillFinishCancelled:NO failed:YES error:error];
        [self handler](nil, nil, error);
        [self requestDidFinishCancelled:NO failed:YES error:error];
    }
}

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request
            redirectResponse:(NSURLResponse *)response
{
    if ([self redirectHandler]) {
        return [self redirectHandler](connection, request, response);
    }
    return request;
}

- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)cachedResponse
{
    if ([self canCache]) {
        return cachedResponse;
    }
    return nil;
}

+ (RCURLRequest *)requestWithURL:(NSURL *)theURL handler:(RCURLRequestHandler)handler
{
    return [self requestWithURL:theURL data:nil handler:handler startImmediately:YES];
}

+ (RCURLRequest *)requestWithURL:(NSURL *)theURL data:(NSData *)theData handler:(RCURLRequestHandler)handler
{
    return [self requestWithURL:theURL data:theData handler:handler startImmediately:YES];
}

+ (RCURLRequest *)requestWithURL:(NSURL *)theURL data:(NSData *)theData
                          method:(NSString *)theMethod handler:(RCURLRequestHandler)handler
{
    return [self requestWithURL:theURL data:theData method:theMethod handler:handler startImmediately:YES];
}

+ (RCURLRequest *)requestWithURL:(NSURL *)theURL method:(NSString *)theMethod
                      parameters:(NSDictionary *)theParameters handler:(RCURLRequestHandler)handler
{
    return [self requestWithURL:theURL method:theMethod parameters:theParameters handler:handler startImmediately:YES];
}

+ (RCURLRequest *)requestWithRequest:(NSURLRequest *)theRequest handler:(RCURLRequestHandler)handler
{
    return [self requestWithRequest:theRequest handler:handler startImmediately:YES];
}

+ (RCURLRequest *)requestWithURL:(NSURL *)theURL
                         handler:(RCURLRequestHandler)handler startImmediately:(BOOL)start
{
    return [self requestWithURL:theURL data:nil handler:handler startImmediately:start];
}

+ (RCURLRequest *)requestWithURL:(NSURL *)theURL data:(NSData *)theData
                         handler:(RCURLRequestHandler)handler startImmediately:(BOOL)start
{
    return [self requestWithURL:theURL data:theData method:nil handler:handler startImmediately:start];
}

+ (RCURLRequest *)requestWithURL:(NSURL *)theURL data:(NSData *)theData
                          method:(NSString *)theMethod
                         handler:(RCURLRequestHandler)handler startImmediately:(BOOL)start
{
    NSMutableURLRequest *theRequest = [NSMutableURLRequest requestWithURL:theURL];
    if (theData) {
        [theRequest setHTTPMethod:theMethod ? theMethod : @"POST"];
        [theRequest setHTTPBody:theData];
    }
    return [self requestWithRequest:theRequest handler:handler startImmediately:start];
}

+ (RCURLRequest *)requestWithURL:(NSURL *)theURL method:(NSString *)theMethod
                      parameters:(NSDictionary *)theParameters handler:(RCURLRequestHandler)handler
                startImmediately:(BOOL)start
{
    NSData *theData = nil;
    NSString *encodedParameters = nil;
    if (theParameters) {
        encodedParameters = [self encodedParameters:theParameters];
    }
    if ([theMethod isEqualToString:@"POST"]) {
        theData = [encodedParameters dataUsingEncoding:NSUTF8StringEncoding];
    } else {
        NSString *URLString = [theURL absoluteString];
        unichar separator = '?';
        if ([[theURL query] length]) {
            separator = '&';
        }
        NSString *newURLString = [NSString stringWithFormat:@"%@%C%@", URLString, separator, encodedParameters];
        theURL = [NSURL URLWithString:newURLString];
    }
    NSMutableURLRequest *theRequest = [NSMutableURLRequest requestWithURL:theURL];
    if (theData) {
        if (!theMethod) {
            theMethod = @"POST";
        }
        [theRequest setHTTPMethod:theMethod];
        if ([theMethod isEqualToString:@"POST"]) {
            [theRequest setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        }
        [theRequest setHTTPBody:theData];
    } else if (theMethod) {
        [theRequest setHTTPMethod:theMethod];
    }
    return [self requestWithRequest:theRequest handler:handler startImmediately:start];
}

+ (RCURLRequest *)requestWithRequest:(NSURLRequest *)theRequest
                             handler:(RCURLRequestHandler)handler startImmediately:(BOOL)start
{
    RCURLRequest *aRequest = [[RCURLRequest alloc] init];
    if ([theRequest isKindOfClass:[NSMutableURLRequest class]]) {
        [aRequest setRequest:(NSMutableURLRequest *)theRequest];
    } else {
        [aRequest setRequest:[[theRequest mutableCopy] autorelease]];
    }
    [aRequest setHandler:handler];
    if (start) {
        [aRequest start];
    }
    return [aRequest autorelease];
}

#pragma mark Utility methods for encoding

+ (NSString *)encodedParameters:(NSDictionary *)theParameters
{
    NSMutableArray *theComponents = [NSMutableArray arrayWithCapacity:[theParameters count]];
    for (NSString *aKey in theParameters) {
        id theValue = [theParameters objectForKey:aKey];
        NSString *stringValue;
        if ([theValue isKindOfClass:[NSString class]]) {
            stringValue = theValue;
        } else if ([theValue respondsToSelector:@selector(stringValue)]) {
            stringValue = [theValue stringValue];
        } else {
            stringValue = [theValue description];
        }
        [theComponents addObject:[NSString stringWithFormat:@"%@=%@", aKey, stringValue]];
    }
    return [theComponents componentsJoinedByString:@"&"];
}

+ (NSString *)URLEncodedString:(NSString *)theString {
    NSString *result = (NSString *)CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                                                           (CFStringRef)theString,
                                                                           NULL,
                                                                           CFSTR(":/=,!$&'()*+;[]@#?"),
                                                                           kCFStringEncodingUTF8);
    return [result autorelease];
}

@end
