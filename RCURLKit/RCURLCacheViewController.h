//
//  RCURLCacheViewController.h
//  RCURLKit
//
//  Created by Alberto García Hierro on 21/01/13.
//  Copyright (c) 2013 Rainy Cape S.L. See LICENSE file.
//

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>

@class RCURLCache;

@interface RCURLCacheViewController : UITableViewController

@property(nonatomic, retain) RCURLCache *cache;

@end
#endif