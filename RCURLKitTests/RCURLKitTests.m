//
//  RCURLKitTests.m
//  RCURLKitTests
//
//  Created by Alberto García Hierro on 14/09/13.
//  Copyright (c) 2013 Rainy Cape S.L. All rights reserved.
//

#import <XCTest/XCTest.h>

#import "RCImageStore.h"

#if TARGET_OS_IPHONE

#define RCImage UIImage

#else

#define RCImage NSImage

#endif

@interface FakeDelegate : NSObject <RCImageStoreDelegate>

@property(nonatomic, copy) RCImageStoreCompletionHandler handler;

@end

@implementation FakeDelegate

- (void)imageStore:(RCImageStore *)imageStore
    didReceiveImage:(UIImage *)theImage
            withURL:(NSURL *)theURL
{
    self.handler(theImage, theURL, nil);
}

- (void)imageStore:(RCImageStore *)imageStore
     failedWithURL:(NSURL *)theURL
             error:(NSError *)theError
{
    self.handler(nil, theURL, theError);
}

@end

@interface RCURLKitTests : XCTestCase

@end

@implementation RCURLKitTests

- (void)setUp
{
    [super setUp];
    // Put setup code here. This method is called before the invocation of each test method in the
    // class.
}

- (void)testFetchImage:(NSString *)imageURL
              resizeTo:(CGSize)toResize
          expectedSize:(CGSize)expectedSize
{
    if (toResize.width > 0 && toResize.height > 0) {
        expectedSize = toResize;
    }
    NSURL *theURL = [NSURL URLWithString:imageURL];
    RCImageStoreCompletionHandler handler = ^(RCImage *image, NSURL *URL, NSError *error) {
        XCTAssertNil(error);
        XCTAssertNotNil(image);
        XCTAssertEqualObjects(theURL, URL);
        CGSize imageSize = image.size;
        XCTAssert(CGSizeEqualToSize(expectedSize, imageSize), @"expected %fx%f, got %fx%f",
                  expectedSize.width, expectedSize.height, imageSize.width, imageSize.height);
    };
    XCTestExpectation *expectation1 = [self expectationWithDescription:@"handler"];
    XCTestExpectation *expectation2 = [self expectationWithDescription:@"delegate"];

    [RCImageStore requestImageWithURL:theURL
                                 size:toResize
                    completionHandler:^(RCImage *image, NSURL *URL, NSError *error) {
                        handler(image, URL, error);
                        [expectation1 fulfill];
                    }];

    FakeDelegate *aDelegate = [[FakeDelegate alloc] init];
    aDelegate.handler = ^(RCImage *image, NSURL *URL, NSError *error) {
        handler(image, URL, error);
        [expectation2 fulfill];
    };

    [RCImageStore requestImageWithURL:theURL size:toResize delegate:aDelegate];
    [self waitForExpectationsWithTimeout:5 handler:nil];
}

- (void)testFetchImage
{
    [self testFetchImage:@"http://upload.wikimedia.org/wikipedia/en/7/70/Example.png"
                resizeTo:CGSizeZero
            expectedSize:CGSizeMake(275, 297)];
}

- (void)testFetchAndResizeImage
{
    [self testFetchImage:@"http://upload.wikimedia.org/wikipedia/en/7/70/Example.png"
                resizeTo:CGSizeMake(50, 50)
            expectedSize:CGSizeZero];
}

@end
