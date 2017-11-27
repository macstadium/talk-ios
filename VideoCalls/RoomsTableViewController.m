//
//  RoomsTableViewController.m
//  VideoCalls
//
//  Created by Ivan Sein on 27.06.17.
//  Copyright © 2017 struktur AG. All rights reserved.
//

#import "RoomsTableViewController.h"

#import "AFNetworking.h"
#import "AuthenticationViewController.h"
#import "CallViewController.h"
#import "RoomTableViewCell.h"
#import "LoginViewController.h"
#import "NCAPIController.h"
#import "NCConnectionController.h"
#import "NCPushNotification.h"
#import "NCSettingsController.h"
#import "NSDate+DateTools.h"
#import "UIImageView+Letters.h"
#import "UIImageView+AFNetworking.h"

@interface RoomsTableViewController () <CallViewControllerDelegate>
{
    NSMutableArray *_rooms;
    BOOL _networkDisconnectedRetry;
    UIRefreshControl *_refreshControl;
    NSTimer *_pingTimer;
    NSString *_currentCallToken;
}

@end

@implementation RoomsTableViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    _rooms = [[NSMutableArray alloc] init];
    _networkDisconnectedRetry = NO;
    
    [self createRefreshControl];
    
    UIImage *image = [UIImage imageNamed:@"navigationLogo"];
    self.navigationItem.titleView = [[UIImageView alloc] initWithImage:image];
    self.navigationController.navigationBar.barTintColor = [UIColor colorWithRed:0.00 green:0.51 blue:0.79 alpha:1.0]; //#0082C9
    self.tabBarController.tabBar.tintColor = [UIColor colorWithRed:0.00 green:0.51 blue:0.79 alpha:1.0]; //#0082C9
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(loginHasBeenCompleted:) name:NCLoginCompletedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pushNotificationReceived:) name:NCPushNotificationReceivedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(joinCallAccepted:) name:NCPushNotificationJoinCallAcceptedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(networkReachabilityHasChanged:) name:NCNetworkReachabilityHasChangedNotification object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self checkConnectionState];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

#pragma mark - Notifications

- (void)loginHasBeenCompleted:(NSNotification *)notification
{
    if ([notification.userInfo objectForKey:kNCTokenKey]) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)pushNotificationReceived:(NSNotification *)notification
{
    NCPushNotification *pushNotification = [NCPushNotification pushNotificationFromDecryptedString:[notification.userInfo objectForKey:@"message"]];
    NSLog(@"Push Notification received: %@", pushNotification);
    if (!_currentCallToken) {
        if (self.presentedViewController) {
            [self dismissViewControllerAnimated:YES completion:^{
                [self presentPushNotificationAlert:pushNotification];
            }];
        } else {
            [self presentPushNotificationAlert:pushNotification];
        }
    }
}

- (void)joinCallAccepted:(NSNotification *)notification
{
    NCPushNotification *pushNotification = [NCPushNotification pushNotificationFromDecryptedString:[notification.userInfo objectForKey:@"message"]];
    [self joinCallWithCallId:pushNotification.pnId];
}

- (void)networkReachabilityHasChanged:(NSNotification *)notification
{
    AFNetworkReachabilityStatus status = [[notification.userInfo objectForKey:kNCNetworkReachabilityKey] intValue];
    NSLog(@"Network Status:%ld", (long)status);
}

#pragma mark - Push Notification Actions

- (void)presentPushNotificationAlert:(NCPushNotification *)pushNotification
{
    UIAlertController * alert = [UIAlertController
                                 alertControllerWithTitle:[pushNotification bodyForRemoteAlerts]
                                 message:@"Do you want to join this call?"
                                 preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *joinButton = [UIAlertAction
                                 actionWithTitle:@"Join call"
                                 style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction * _Nonnull action) {
                                     [self joinCallWithCallId:pushNotification.pnId];
                                 }];
    
    UIAlertAction* cancelButton = [UIAlertAction
                                   actionWithTitle:@"Cancel"
                                   style:UIAlertActionStyleCancel
                                   handler:nil];
    
    [alert addAction:joinButton];
    [alert addAction:cancelButton];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)joinCallWithCallId:(NSInteger)callId
{
    NSString *callToken = nil;
    
    if (_rooms) {
        for (NCRoom *room in _rooms) {
            if (room.roomId == callId) {
                callToken = room.token;
                [self presentCallViewControllerForCallToken:callToken];
            }
        }
        
        if (!callToken) {
            [self searchForCallInServer:callId];
        }
    }
}

- (void)searchForCallInServer:(NSInteger)callId
{
    [[NCAPIController sharedInstance] getRoomsWithCompletionBlock:^(NSMutableArray *rooms, NSError *error, NSInteger errorCode) {
        if (!error) {
            for (NCRoom *room in rooms) {
                if (room.roomId == callId) {
                    [self presentCallViewControllerForCallToken:room.token];
                }
            }
        } else {
            NSLog(@"Error while searching for call: %@", error);
        }
    }];
}

#pragma mark - Interface Builder Actions

- (IBAction)addButtonPressed:(id)sender
{
    UIAlertController *optionsActionSheet =
    [UIAlertController alertControllerWithTitle:nil
                                        message:nil
                                 preferredStyle:UIAlertControllerStyleActionSheet];
    
    [optionsActionSheet addAction:[UIAlertAction actionWithTitle:@"New public call"
                                                           style:UIAlertActionStyleDefault
                                                         handler:^void (UIAlertAction *action) {
                                                             [self createNewPublicRoom];
                                                         }]];
    
    [optionsActionSheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    // Presentation on iPads
    UIPopoverPresentationController *popController = [optionsActionSheet popoverPresentationController];
    popController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    popController.barButtonItem = self.navigationItem.rightBarButtonItem;
    
    [self presentViewController:optionsActionSheet animated:YES completion:nil];
}

#pragma mark - Refresh Control

- (void)createRefreshControl
{
    _refreshControl = [UIRefreshControl new];
    _refreshControl.tintColor = [UIColor colorWithRed:0.00 green:0.51 blue:0.79 alpha:1.0]; //#0082C9
    _refreshControl.backgroundColor = [UIColor colorWithRed:235.0/255.0 green:235.0/255.0 blue:235.0/255.0 alpha:1.0];
    [_refreshControl addTarget:self action:@selector(refreshControlTarget) forControlEvents:UIControlEventValueChanged];
    [self setRefreshControl:_refreshControl];
}

- (void)deleteRefreshControl
{
    [_refreshControl endRefreshing];
    self.refreshControl = nil;
}

- (void)refreshControlTarget
{
    [self getRooms];
    
    // Actuate `Peek` feedback (weak boom)
    AudioServicesPlaySystemSound(1519);
}

#pragma mark - Rooms

- (void)checkConnectionState
{
    ConnectionState connectionState = [[NCConnectionController sharedInstance] connectionState];
    
    switch (connectionState) {
        case kConnectionStateNotServerProvided:
        {
            LoginViewController *loginVC = [[LoginViewController alloc] init];
            [self presentViewController:loginVC animated:YES completion:nil];
        }
            break;
        case kConnectionStateAuthenticationNeeded:
        {
            AuthenticationViewController *authVC = [[AuthenticationViewController alloc] init];
            [self presentViewController:authVC animated:YES completion:nil];
        }
            break;
            
        case kConnectionStateNetworkDisconnected:
        {
            NSLog(@"No network connection!");
            if (!_networkDisconnectedRetry) {
                _networkDisconnectedRetry = YES;
                double delayInSeconds = 1.0;
                dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
                dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
                    [self checkConnectionState];
                });
            }
        }
            break;
            
        default:
        {
            [self getRooms];
            _networkDisconnectedRetry = NO;
        }
            break;
    }
}

- (void)getRooms
{
    [[NCAPIController sharedInstance] getRoomsWithCompletionBlock:^(NSMutableArray *rooms, NSError *error, NSInteger errorCode) {
        if (!error) {
            _rooms = rooms;
            [self.tableView reloadData];
            NSLog(@"Rooms updated");
        } else {
            NSLog(@"Error while trying to get rooms: %@", error);
        }
        
        [_refreshControl endRefreshing];
    }];
}

- (void)startPingCall
{
    [self pingCall];
    _pingTimer = [NSTimer scheduledTimerWithTimeInterval:5.0  target:self selector:@selector(pingCall) userInfo:nil repeats:YES];
}

- (void)pingCall
{
    if (_currentCallToken) {
        [[NCAPIController sharedInstance] pingCall:_currentCallToken withCompletionBlock:^(NSError *error, NSInteger errorCode) {
            //TODO: Error handling
        }];
    } else {
        NSLog(@"No call token to ping");
    }
}

#pragma mark - Room actions

- (void)renameRoomAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    
    UIAlertController *renameDialog =
    [UIAlertController alertControllerWithTitle:@"Enter new name:"
                                        message:nil
                                 preferredStyle:UIAlertControllerStyleAlert];
    
    [renameDialog addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"Name";
        textField.text = room.displayName;
    }];
    
    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *newRoomName = [[renameDialog textFields][0] text];
        NSLog(@"New room name %@", newRoomName);
        [[NCAPIController sharedInstance] renameRoom:room.token withName:newRoomName andCompletionBlock:^(NSError *error, NSInteger errorCode) {
            if (!error) {
                [self getRooms];
            } else {
                NSLog(@"Error renaming the room: %@", error.description);
                //TODO: Error handling
            }
        }];
    }];
    [renameDialog addAction:confirmAction];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [renameDialog addAction:cancelAction];
    
    [self presentViewController:renameDialog animated:YES completion:nil];
}

- (void)shareLinkFromRoomAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    NSString *shareMessage = [NSString stringWithFormat:@"You can join to this call: %@/index.php/call/%@", [[NCAPIController sharedInstance] currentServerUrl], room.token];
    NSArray *items = @[shareMessage];
    
    UIActivityViewController *controller = [[UIActivityViewController alloc]initWithActivityItems:items applicationActivities:nil];
    
    // Presentation on iPads
    controller.popoverPresentationController.sourceView = self.tableView;
    controller.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
    
    [self presentViewController:controller animated:YES completion:nil];
    
    controller.completionWithItemsHandler = ^(NSString *activityType,
                                              BOOL completed,
                                              NSArray *returnedItems,
                                              NSError *error) {
        if (error) {
            NSLog(@"An Error occured sharing room: %@, %@", error.localizedDescription, error.localizedFailureReason);
        }
    };
}

- (void)makePublicRoomAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    [[NCAPIController sharedInstance] makeRoomPublic:room.token withCompletionBlock:^(NSError *error, NSInteger errorCode) {
        if (!error) {
            [self getRooms];
            [self shareLinkFromRoomAtIndexPath:indexPath];
        } else {
            NSLog(@"Error making public the room: %@", error.description);
            //TODO: Error handling
        }
    }];
}

- (void)makePrivateRoomAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    [[NCAPIController sharedInstance] makeRoomPrivate:room.token withCompletionBlock:^(NSError *error, NSInteger errorCode) {
        if (!error) {
            [self getRooms];
        } else {
            NSLog(@"Error making private the room: %@", error.description);
            //TODO: Error handling
        }
    }];
}

- (void)setPasswordToRoomAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    
    UIAlertController *renameDialog =
    [UIAlertController alertControllerWithTitle:@"Set password:"
                                        message:nil
                                 preferredStyle:UIAlertControllerStyleAlert];
    
    [renameDialog addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"Password";
        textField.secureTextEntry = YES;
    }];
    
    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *password = [[renameDialog textFields][0] text];
        [[NCAPIController sharedInstance] setPassword:password toRoom:room.token withCompletionBlock:^(NSError *error, NSInteger errorCode) {
            if (!error) {
                [self getRooms];
            } else {
                NSLog(@"Error setting room password: %@", error.description);
                //TODO: Error handling
            }
        }];
    }];
    [renameDialog addAction:confirmAction];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [renameDialog addAction:cancelAction];
    
    [self presentViewController:renameDialog animated:YES completion:nil];
}

- (void)leaveRoomAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    [[NCAPIController sharedInstance] removeSelfFromRoom:room.token withCompletionBlock:^(NSError *error, NSInteger errorCode) {
        if (error) {
            //TODO: Error handling
        }
    }];
    
    [_rooms removeObjectAtIndex:indexPath.row];
    [self.tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
}

- (void)deleteRoomAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    [[NCAPIController sharedInstance] deleteRoom:room.token withCompletionBlock:^(NSError *error, NSInteger errorCode) {
        if (error) {
            //TODO: Error handling
        }
    }];
    
    [_rooms removeObjectAtIndex:indexPath.row];
    [self.tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
}

- (void)createNewPublicRoom
{
    [[NCAPIController sharedInstance] createRoomWith:nil ofType:kNCRoomTypePublicCall withCompletionBlock:^(NSString *token, NSError *error, NSInteger errorCode) {
        if (!error) {
            [self getRooms];
        } else {
            NSLog(@"Error creating new public room: %@", error.description);
            //TODO: Error handling
        }
    }];
}

#pragma mark - Calls

- (void)presentCallViewControllerForCallToken:(NSString *)token
{
    CallViewController *callVC = [[CallViewController alloc] initCallInRoom:token asUser:[[NCSettingsController sharedInstance] ncUserDisplayName]];
    callVC.delegate = self;
    [self presentViewController:callVC animated:YES completion:^{
        // Disable sleep timer
        [UIApplication sharedApplication].idleTimerDisabled = YES;
    }];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return _rooms.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return 60.0f;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewCellEditingStyleDelete;
}

- (NSString *)tableView:(UITableView *)tableView titleForSwipeAccessoryButtonForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    
    if (room.canModerate) {
        NSString *moreButtonText = @"More";
        return moreButtonText;
    }
    
    return nil;
}

- (void)tableView:(UITableView *)tableView swipeAccessoryButtonPushedForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    
    UIAlertController *optionsActionSheet =
    [UIAlertController alertControllerWithTitle:room.displayName
                                        message:nil
                                 preferredStyle:UIAlertControllerStyleActionSheet];
    // Rename
    if (room.isNameEditable) {
        [optionsActionSheet addAction:[UIAlertAction actionWithTitle:@"Rename"
                                                               style:UIAlertActionStyleDefault
                                                             handler:^void (UIAlertAction *action) {
                                                                 [self renameRoomAtIndexPath:indexPath];
                                                             }]];
    }
    
    // Public/Private room options
    if (room.isPublic) {
        
        // Set Password
        NSString *passwordOptionTitle = @"Set password";
        if (room.hasPassword) {
            passwordOptionTitle = @"Change password";
        }
        [optionsActionSheet addAction:[UIAlertAction actionWithTitle:passwordOptionTitle
                                                               style:UIAlertActionStyleDefault
                                                             handler:^void (UIAlertAction *action) {
                                                                 [self setPasswordToRoomAtIndexPath:indexPath];
                                                             }]];
        
        // Share Link
        [optionsActionSheet addAction:[UIAlertAction actionWithTitle:@"Share link"
                                                               style:UIAlertActionStyleDefault
                                                             handler:^void (UIAlertAction *action) {
                                                                 [self shareLinkFromRoomAtIndexPath:indexPath];
                                                             }]];
        
        // Make call private
        [optionsActionSheet addAction:[UIAlertAction actionWithTitle:@"Stop sharing call"
                                                               style:UIAlertActionStyleDestructive
                                                             handler:^void (UIAlertAction *action) {
                                                                 [self makePrivateRoomAtIndexPath:indexPath];
                                                             }]];
    } else {
        // Make call public
        [optionsActionSheet addAction:[UIAlertAction actionWithTitle:@"Share link"
                                                               style:UIAlertActionStyleDefault
                                                             handler:^void (UIAlertAction *action) {
                                                                 [self makePublicRoomAtIndexPath:indexPath];
                                                             }]];
    }
    
    // Delete room
    if (room.isDeletable) {
        [optionsActionSheet addAction:[UIAlertAction actionWithTitle:@"Delete call"
                                                               style:UIAlertActionStyleDestructive
                                                             handler:^void (UIAlertAction *action) {
                                                                 [self deleteRoomAtIndexPath:indexPath];
                                                             }]];
    }
    
    [optionsActionSheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    // Presentation on iPads
    optionsActionSheet.popoverPresentationController.sourceView = tableView;
    optionsActionSheet.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    
    [self presentViewController:optionsActionSheet animated:YES completion:nil];
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSString *deleteButtonText = @"Leave";
    return deleteButtonText;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        [self leaveRoomAtIndexPath:indexPath];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    RoomTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kRoomCellIdentifier];
    if (!cell) {
        cell = [[RoomTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kRoomCellIdentifier];
    }
    
    // Set room name
    cell.labelTitle.text = room.displayName;
    
    // Set last ping
    NSDate *date = [[NSDate alloc] initWithTimeIntervalSince1970:room.lastPing];
    cell.labelSubTitle.text = [date timeAgoSinceNow];
    
    if (room.lastPing == 0) {
        cell.labelSubTitle.text = @"Never";
    }
    
    // Set room image
    switch (room.type) {
        case kNCRoomTypeOneToOneCall:
        {
            // Create avatar for every OneToOne call
            [cell.roomImage setImageWithString:room.displayName color:nil circular:true];
            
            // Request user avatar to the server and set it if exist
            [cell.roomImage setImageWithURLRequest:[[NCAPIController sharedInstance] createAvatarRequestForUser:room.name]
                                  placeholderImage:nil
                                           success:nil
                                           failure:nil];
            
            cell.roomImage.layer.cornerRadius = 24.0;
            cell.roomImage.layer.masksToBounds = YES;
        }
            break;
            
        case kNCRoomTypeGroupCall:
            [cell.roomImage setImage:[UIImage imageNamed:@"group"]];
            break;
            
        case kNCRoomTypePublicCall:
            [cell.roomImage setImage:[UIImage imageNamed:@"public"]];
            break;
            
        default:
            break;
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NCRoom *room = [_rooms objectAtIndex:indexPath.row];
    
    _currentCallToken = room.token;
    [self presentCallViewControllerForCallToken:_currentCallToken];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

#pragma mark - CallViewControllerDelegate

- (void)viewControllerDidFinish:(CallViewController *)viewController {
    if (![viewController isBeingDismissed]) {
        [self dismissViewControllerAnimated:YES completion:^{
            NSLog(@"Call view controller dismissed");
            _currentCallToken = nil;
            // Enable sleep timer
            [UIApplication sharedApplication].idleTimerDisabled = NO;
        }];
    }
}


@end
