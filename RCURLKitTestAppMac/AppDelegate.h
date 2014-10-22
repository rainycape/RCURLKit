//
//  AppDelegate.h
//  RCURLKitTestAppMac
//
//  Created by Alberto García Hierro on 22/10/14.
//  Copyright (c) 2014 Rainy Cape S.L. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property(nonatomic, strong) IBOutlet NSImageView *imageView;
@property(nonatomic, strong) IBOutlet NSTextField *width;
@property(nonatomic, strong) IBOutlet NSTextField *height;
@property(nonatomic, strong) IBOutlet NSTextField *URL;

- (IBAction)updateImage:(id)sender;

@end
