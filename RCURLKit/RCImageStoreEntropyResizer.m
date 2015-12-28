//
//  RCImageStoreEntropyResizer.m
//  RCURLKit
//
//  Created by Alberto García Hierro on 21/2/15.
//  Copyright (c) 2015 Rainy Cape S.L. All rights reserved.
//

#import "RCImageStoreEntropyResizer.h"

@implementation RCImageStoreEntropyResizer

- (CGImageRef)imageByResizingImage:(CGImageRef)theImage
                            toSize:(CGSize)theSize
                      resizingType:(RCImageStoreResizingType)resizingType
{
    CGSize imageSize = CGSizeMake(CGImageGetWidth(theImage), CGImageGetHeight(theImage));
    CGColorSpaceRef colorspace = CGColorSpaceCreateDeviceRGB();
    size_t pixels = ((size_t)theSize.width) * ((size_t)theSize.height);
    uint8_t *data = malloc(pixels * 4);
    CGContextRef ctx
        = CGBitmapContextCreate(data, theSize.width, theSize.height, 8, ((size_t)theSize.width) * 4,
                                colorspace, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);

    // Scale and move
    CGFloat widthRatio = theSize.width / imageSize.width;
    CGFloat heightRatio = theSize.height / imageSize.height;

    CGFloat ratio;
    if (widthRatio < heightRatio) {
        // Crop width
        ratio = heightRatio;
    } else {
        // Crop height
        ratio = widthRatio;
    }
    CGPoint trans = CGPointZero;
    CGPoint bestTrans = CGPointZero;
    NSInteger bestColors = 0;
    CGPoint maxTrans = CGPointMake(roundf(imageSize.width * ratio - theSize.width),
                                   roundf(imageSize.height * ratio - theSize.height));
    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    CGRect imageRect = (CGRect){ CGPointZero, imageSize };
    for (; trans.x <= maxTrans.x; trans.x = MIN(trans.x + 10, maxTrans.x)) {
        trans.y = 0;
        for (; trans.y <= maxTrans.y; trans.y = MIN(trans.y + 10, maxTrans.y)) {
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, -trans.x, -trans.y);
            CGContextScaleCTM(ctx, ratio, ratio);
            CGContextDrawImage(ctx, imageRect, theImage);
            NSInteger numberOfColors = [self numberOfColorsWithData:data pixels:pixels];
            if (numberOfColors > bestColors) {
                bestColors = numberOfColors;
                bestTrans = trans;
            }
            CGContextClearRect(ctx, imageRect);
            CGContextRestoreGState(ctx);
            if (trans.y == maxTrans.y) {
                break;
            }
        }
        if (trans.x == maxTrans.x) {
            break;
        }
    }

    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextTranslateCTM(ctx, -bestTrans.x, -bestTrans.y);
    CGContextScaleCTM(ctx, ratio, ratio);
    CGContextDrawImage(ctx, imageRect, theImage);
    CGImageRef imageRef = CGBitmapContextCreateImage(ctx);
    CGColorSpaceRelease(colorspace);
    CGContextRelease(ctx);
    free(data);
    return imageRef;
}

- (NSInteger)numberOfColorsWithData:(uint8_t *)data pixels:(size_t)pixels
{
    NSMutableSet *colors = [[NSMutableSet alloc] init];
    for (size_t ii = 0; ii < pixels; ii += 4) {
        uint8_t red = data[ii];
        uint8_t green = data[ii + 1];
        uint8_t blue = data[ii + 2];
        // Convert RGB888 to RGB444, to make similar colors
        // count as one.
        uint16_t color = ((red / 2) << 8) | ((green / 2) << 4) | (blue / 2);
        [colors addObject:@(color)];
    }
    return colors.count;
}

@end
