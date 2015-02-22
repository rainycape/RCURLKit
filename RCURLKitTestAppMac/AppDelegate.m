//
//  AppDelegate.m
//  RCURLKitTestAppMac
//
//  Created by Alberto García Hierro on 22/10/14.
//  Copyright (c) 2014 Rainy Cape S.L. All rights reserved.
//

#import "RCImageStore.h"

#import "AppDelegate.h"

@interface AppDelegate ()

@property(weak) IBOutlet NSWindow *window;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    NSUserDefaults *standardUserDefaults = [NSUserDefaults standardUserDefaults];
    if ([standardUserDefaults objectForKey:@"width"]) {
        [self.width setFloatValue:[standardUserDefaults floatForKey:@"width"]];
    }
    if ([standardUserDefaults objectForKey:@"height"]) {
        [self.height setFloatValue:[standardUserDefaults floatForKey:@"height"]];
    }
    if ([standardUserDefaults objectForKey:@"URL"]) {
        [self.URL setStringValue:[standardUserDefaults objectForKey:@"URL"]];
        [self updateImage:nil];
    }
}

- (void)applicationWillTerminate:(NSNotification *)aNotification
{
    // Insert code here to tear down your application
}

- (IBAction)updateImage:(id)sender
{
    CGFloat width = [self.width floatValue];
    CGFloat height = [self.height floatValue];
    NSString *URL = [self.URL stringValue];
    NSUserDefaults *standardUserDefaults = [NSUserDefaults standardUserDefaults];
    [standardUserDefaults setFloat:width forKey:@"width"];
    [standardUserDefaults setFloat:height forKey:@"height"];
    [standardUserDefaults setObject:URL forKey:@"URL"];
    [standardUserDefaults synchronize];
    if (URL) {
        [RCImageStore requestImageWithURL:[NSURL URLWithString:URL]
                                     size:CGSizeMake(width, height)
                        completionHandler:^(NSImage *image, NSURL *URL, NSError *error) {
                            if (error) {
                                [[NSAlert alertWithError:error] runModal];
                                return;
                            }
                            self.imageView.image = image;
                        }];
    }
}

@end
