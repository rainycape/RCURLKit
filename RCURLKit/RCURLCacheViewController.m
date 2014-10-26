//
//  RCURLCacheViewController.m
//  RCURLKit
//
//  Created by Alberto García Hierro on 21/01/13.
//  Copyright (c) 2013 Rainy Cape S.L. See LICENSE file.
//

#import <QuartzCore/QuartzCore.h>

#import "RCURLCache.h"

#import "RCURLCacheViewController.h"

@interface RCURLCacheViewController () <UIActionSheetDelegate>

@property(nonatomic, retain) NSDictionary *diskUsage;
@property(nonatomic, getter=isClearing) BOOL clearing;

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
        [defaultCenter addObserver:self
                          selector:@selector(beganClearingCache:)
                              name:RCURLCacheBeganClearingNotification
                            object:nil];
        [defaultCenter addObserver:self
                          selector:@selector(finishedClearingCache:)
                              name:RCURLCacheFinishedClearingNotification
                            object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *CellIdentifier = @"Cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:CellIdentifier];
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
        cell.textLabel.textColor = [UIColor darkTextColor];
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 1) {
        cell.textLabel.text = NSLocalizedString(@"Total", nil);
        unsigned long long val = 0;
        for (NSNumber *aNumber in [diskUsage allValues]) {
            val += [aNumber unsignedLongLongValue];
        }
        NSNumber *theValue = [NSNumber numberWithLongLong:val];
        cell.detailTextLabel.text = [self stringWithHumanReadableSize:theValue];
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.textColor = [UIColor darkTextColor];
    } else if (indexPath.section == 2) {
        cell.textLabel.text = NSLocalizedString(@"Clear", nil);
        cell.detailTextLabel.text = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryView = nil;
        cell.textLabel.textColor = self.view.tintColor;
        if ([self isClearing]) {
            UIActivityIndicatorView *indicatorView = [[UIActivityIndicatorView alloc]
                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
            [indicatorView sizeToFit];
            [indicatorView startAnimating];
            cell.accessoryView = indicatorView;
        }
    }
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 2) {

        UIActionSheet *actionSheet = [[UIActionSheet alloc]
                     initWithTitle:NSLocalizedString(@"This will remove all cached items.", nil)
                          delegate:self
                 cancelButtonTitle:NSLocalizedString(@"Cancel", nil)
            destructiveButtonTitle:NSLocalizedString(@"Clear Cache", nil)
                 otherButtonTitles:nil];
        [actionSheet showInView:self.view];

        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
}

#pragma mark - UIActionSheetDelegate

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex != actionSheet.cancelButtonIndex) {
        [[RCURLCache sharedCache] clear];
    }
}

#pragma mark - Utility functions

- (NSString *)stringWithHumanReadableSize:(NSNumber *)theSize
{
    NSNumberFormatter *numberFormatter = [[NSNumberFormatter alloc] init];
    [numberFormatter setMinimumFractionDigits:2];
    [numberFormatter setMaximumFractionDigits:2];
    unsigned long long val = [theSize unsignedLongLongValue];
    if (val < 1024) {
        [numberFormatter setMinimumFractionDigits:0];
        return [NSString stringWithFormat:@"%@ bytes", [numberFormatter stringFromNumber:theSize]];
    }
    if (val < 1024 * 1024) {
        return [NSString
            stringWithFormat:@"%@ KB",
                             [numberFormatter
                                 stringFromNumber:[NSNumber numberWithFloat:val / 1024.0]]];
    }
    if (val < 1024 * 1024 * 1024) {
        return [NSString
            stringWithFormat:
                @"%@ MB", [numberFormatter
                              stringFromNumber:[NSNumber numberWithFloat:val / (1024.0 * 1024.0)]]];
    }
    return [NSString
        stringWithFormat:@"%@ GB",
                         [numberFormatter
                             stringFromNumber:[NSNumber numberWithFloat:val / (1024.0 * 1024.0
                                                                               * 1024.0)]]];
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