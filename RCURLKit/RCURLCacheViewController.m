//
//  RCURLCacheViewController.m
//  RCURLKit
//
//  Created by Alberto García Hierro on 21/01/13.
//  Copyright (c) 2013 Rainy Cape S.L. See LICENSE file.
//

#if TARGET_OS_IPHONE
#import <QuartzCore/QuartzCore.h>

#import "RCURLCache.h"

#import "RCURLCacheViewController.h"

@interface RCURLCacheViewController ()

@property(nonatomic, retain) NSDictionary *diskUsage;
@property(nonatomic, getter = isClearing) BOOL clearing;

@end

@implementation RCURLCacheViewController

- (id)init
{
    return [self initWithStyle:UITableViewStyleGrouped];
}

- (id)initWithStyle:(UITableViewStyle)style
{
    if ((self = [super initWithStyle:style])) {
        [self setTitle:NSLocalizedString(@"Cache", nil)];
        NSNotificationCenter *defaultCenter = [NSNotificationCenter defaultCenter];
        [defaultCenter addObserver:self selector:@selector(beganClearingCache:)
                              name:RCURLCacheBeganClearingNotification object:nil];
        [defaultCenter addObserver:self selector:@selector(finishedClearingCache:)
                              name:RCURLCacheFinishedClearingNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_diskUsage release];
    [_cache release];
    [super dealloc];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) {
        if (![self diskUsage]) {
            [self updateDiskUsage];
        }
        return [[self diskUsage] count];
    }
    if (section == 1) {
        return 1;
    }
    return 0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    if (section == 2) {
        return 44;
    }
    return 0;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section
{
    if (section == 2) {
        CGFloat margin = 10;
        CGFloat width = CGRectGetWidth([tableView bounds]);
        UIView *theContainer = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 44)] autorelease];
        [theContainer setBackgroundColor:[UIColor clearColor]];
        [theContainer setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
        CGRect buttonFrame = CGRectInset([theContainer bounds], margin, 0);
        UIButton *theButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [theButton setFrame:buttonFrame];
        [theButton setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
        [[theButton titleLabel] setFont:[UIFont boldSystemFontOfSize:19]];
        [theButton setTitleShadowColor:[UIColor blackColor] forState:UIControlStateNormal];
        [[theButton titleLabel] setShadowOffset:CGSizeMake(0, 1)];
        if ([self isClearing]) {
            [theButton setEnabled:NO];
            UIActivityIndicatorView *indicatorView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
            [indicatorView sizeToFit];
            [indicatorView startAnimating];
            [indicatorView setAutoresizingMask:~(UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight)];
            [indicatorView setCenter:CGPointMake(CGRectGetMidX(buttonFrame), 22)];
            [theButton addSubview:indicatorView];
            [indicatorView release];
        } else {
            [theButton setTitle:NSLocalizedString(@"Clear", nil) forState:UIControlStateNormal];
        }
        UIImage *backgroundImage = [UIImage imageNamed:@"RCURLCache.bundle/ClearButtonNormal.png"];
        [theButton setBackgroundImage:[backgroundImage stretchableImageWithLeftCapWidth:6 topCapHeight:22]
                             forState:UIControlStateNormal];
        UIImage *pressedImage = [UIImage imageNamed:@"RCURLCache.bundle/ClearButtonPressed.png"];
        [theButton setBackgroundImage:[pressedImage stretchableImageWithLeftCapWidth:6 topCapHeight:22]
                             forState:UIControlStateHighlighted];
        [theButton addTarget:self action:@selector(clearCache:) forControlEvents:UIControlEventTouchUpInside];
        [theContainer addSubview:theButton];
        return theContainer;
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *CellIdentifier = @"Cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                       reuseIdentifier:CellIdentifier] autorelease];
        [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
    }
    NSDictionary *diskUsage = [self diskUsage];
    if (indexPath.section == 0) {
        NSMutableArray *theKeys = [NSMutableArray arrayWithArray:[diskUsage allKeys]];
        [theKeys sortUsingSelector:@selector(compare:)];
        NSNumber *theKey = [theKeys objectAtIndex:indexPath.row];
        RCURLCacheDocumentType documentType = [theKey intValue];
        switch (documentType) {
            case RCURLCacheDocumentTypeOther:
                cell.textLabel.text = NSLocalizedString(@"Other", nil);
                break;
            case RCURLCacheDocumentTypeImage:
                cell.textLabel.text = NSLocalizedString(@"Images", nil);
                break;
            case RCURLCacheDocumentTypePage:
                cell.textLabel.text = NSLocalizedString(@"Pages", nil);
                break;
            case RCURLCacheDocumentTypeVideo:
                cell.textLabel.text = NSLocalizedString(@"Video", nil);
                break;
        }
        NSNumber *theValue = [diskUsage objectForKey:theKey];
        cell.detailTextLabel.text = [self stringWithHumanReadableSize:theValue];
    } else {
        cell.textLabel.text = NSLocalizedString(@"Total", nil);
        unsigned long long val = 0;
        for (NSNumber *aNumber in [diskUsage allValues]) {
            val += [aNumber unsignedLongLongValue];
        }
        NSNumber *theValue = [NSNumber numberWithLongLong:val];
        cell.detailTextLabel.text = [self stringWithHumanReadableSize:theValue];
    }
    return cell;
}

#pragma mark - Utility functions

- (NSString *)stringWithHumanReadableSize:(NSNumber *)theSize
{
    NSNumberFormatter *numberFormatter = [[[NSNumberFormatter alloc] init] autorelease];
    [numberFormatter setMinimumFractionDigits:2];
    [numberFormatter setMaximumFractionDigits:2];
    unsigned long long val = [theSize unsignedLongLongValue];
    if (val < 1024) {
        [numberFormatter setMinimumFractionDigits:0];
        return [NSString stringWithFormat:@"%@ bytes",
                [numberFormatter stringFromNumber:theSize]];
    }
    if (val < 1024 * 1024) {
        return [NSString stringWithFormat:@"%@ KB",
                [numberFormatter stringFromNumber:[NSNumber numberWithFloat:val / 1024.0]]];
    }
    if (val < 1024 * 1024 * 1024) {
        return [NSString stringWithFormat:@"%@ MB",
                [numberFormatter stringFromNumber:[NSNumber numberWithFloat:val / (1024.0 * 1024.0)]]];
    }
    return [NSString stringWithFormat:@"%@ GB",
            [numberFormatter stringFromNumber:[NSNumber numberWithFloat:val / (1024.0 * 1024.0 * 1024.0)]]];
}

- (void)reloadDataAnimated
{
    CATransition *aTransition = [CATransition animation];
    [[[self tableView] layer] addAnimation:aTransition forKey:kCATransition];
    [[self tableView] reloadData];
}

- (void)updateDiskUsage
{
    RCURLCache *cache = [self cache] ?: [RCURLCache sharedCache];
    [self setDiskUsage:[cache diskUsage]];
}

#pragma mark - Action handlers

- (void)clearCache:(UIButton *)sender
{
    [[RCURLCache sharedCache] clear];
}

#pragma mark - NSNotification handlers

- (void)beganClearingCache:(NSNotification *)aNotification
{
    [self setClearing:YES];
    [self reloadDataAnimated];
}

- (void)finishedClearingCache:(NSNotification *)aNotification
{
    [self setClearing:NO];
    [self updateDiskUsage];
    [self reloadDataAnimated];
}

@end

#endif
