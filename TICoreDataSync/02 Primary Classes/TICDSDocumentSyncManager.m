//
//  TICDSDocumentSyncManager.m
//  ShoppingListMac
//
//  Created by Tim Isted on 22/04/2011.
//  Copyright 2011 Tim Isted. All rights reserved.
//

#import "TICoreDataSync.h"

@interface TICDSDocumentSyncManager () <TICoreDataFactoryDelegate>

- (BOOL)startDocumentConfigurationProcess:(NSError **)outError;
- (BOOL)startDocumentRegistrationProcess:(NSError **)outError;
- (void)bailFromRegistrationProcessWithError:(NSError *)anError;
- (BOOL)checkForHelperFileDirectoryOrCreateIfNecessary:(NSError **)outError;

- (void)startWholeStoreUploadProcess;
- (void)bailFromUploadProcessWithError:(NSError *)anError;

- (void)startSynchronizationProcess;
- (void)bailFromSynchronizationProcessWithError:(NSError *)anError;
- (void)moveUnsynchronizedSyncChangesToMergeLocation;

- (void)startVacuumProcess;
- (void)bailFromVacuumProcessWithError:(NSError *)anError;

- (void)startWholeStoreDownloadProcess;
- (void)bailFromDownloadProcessWithError:(NSError *)anError;

- (NSManagedObjectContext *)addSyncChangesMocForDocumentMoc:(NSManagedObjectContext *)aContext;
- (NSString *)keyForContext:(NSManagedObjectContext *)aContext;

- (void)startRegisteredDevicesInformationProcess;
- (void)bailFromRegisteredDevicesInformationProcessWithError:(NSError *)anError;

- (void)startClientDeletionProcessForClient:(NSString *)anIdentifier;
- (void)bailFromClientDeletionProcessForClient:(NSString *)anIdentifier withError:(NSError *)anError;

@property (nonatomic, copy) NSString *documentIdentifier;
@property (nonatomic, copy) NSString *documentDescription;
@property (nonatomic, copy) NSString *clientIdentifier;
@property (nonatomic, strong) NSDictionary *documentUserInfo;
@property (strong) NSURL *helperFileDirectoryLocation;

@end

@implementation TICDSDocumentSyncManager

#pragma mark - ACTIVITY

- (void)postIncreaseActivityNotification
{
    [[NSNotificationCenter defaultCenter] postNotificationName:TICDSDocumentSyncManagerDidIncreaseActivityNotification object:self];
}

- (void)postDecreaseActivityNotification
{
    [[NSNotificationCenter defaultCenter] postNotificationName:TICDSDocumentSyncManagerDidDecreaseActivityNotification object:self];
}

#pragma mark - LOCAL HELPER FILE REMOVAL

- (void)removeLocalHelperFiles:(NSError **)error
{
    if ([self.fileManager fileExistsAtPath:[self.helperFileDirectoryLocation path]]) {
        [self.fileManager removeItemAtPath:[self.helperFileDirectoryLocation path] error:error];
    }
    
    if ([self.fileManager fileExistsAtPath:[self.defaultHelperFileLocation path]]) {
        [self.fileManager removeItemAtPath:[self.defaultHelperFileLocation path] error:error];
    }
}

#pragma mark - DELAYED REGISTRATION

- (void)configureWithDelegate:(id <TICDSDocumentSyncManagerDelegate>)aDelegate appSyncManager:(TICDSApplicationSyncManager *)anAppSyncManager managedObjectContext:(NSManagedObjectContext *)aContext documentIdentifier:(NSString *)aDocumentIdentifier description:(NSString *)aDocumentDescription userInfo:(NSDictionary *)someUserInfo
{
    [self preConfigureWithDelegate:aDelegate appSyncManager:anAppSyncManager documentIdentifier:aDocumentIdentifier];

    self.primaryDocumentMOC = aContext;
    self.primaryDocumentMOC.documentSyncManager = self;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(synchronizedMOCDidSave:) name:NSManagedObjectContextDidSaveNotification object:self.primaryDocumentMOC];

    // setup the syncChangesMOC
    TICDSLog(TICDSLogVerbosityEveryStep, @"Creating SyncChangesMOC");

    [self addSyncChangesMocForDocumentMoc:self.primaryDocumentMOC];
    if ([self syncChangesMocForDocumentMoc:self.primaryDocumentMOC] == nil) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to create sync changes MOC");
        [self bailFromRegistrationProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeFailedToCreateSyncChangesMOC classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }
    TICDSLog(TICDSLogVerbosityEveryStep, @"Finished creating SyncChangesMOC");

    TICDSLog(TICDSLogVerbosityEveryStep, @"Registration Information:\n   Delegate: %@,\n   App Sync Manager: %@,\n   Document ID: %@,\n   Description: %@,\n   User Info: %@", aDelegate, anAppSyncManager, aDocumentIdentifier, aDocumentDescription, someUserInfo);
    self.applicationSyncManager = anAppSyncManager;
    self.documentDescription = aDocumentDescription;
    NSString *userDefaultsIntegrityKey = [TICDSUtilities userDefaultsKeyForIntegrityKeyForDocumentWithIdentifier:aDocumentIdentifier];
    NSString *integrityKey = [[NSUserDefaults standardUserDefaults] valueForKey:userDefaultsIntegrityKey];
    self.integrityKey = integrityKey;
    self.clientIdentifier = [anAppSyncManager clientIdentifier];
    self.documentUserInfo = someUserInfo;

    TICDSLog(TICDSLogVerbosityStartAndEndOfMainPhase, @"Document sync manager configured for future registration");
}

- (void)registerConfiguredDocumentSyncManager
{
    if (self.isConfigured == NO) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Can't register this document sync manager because it wasn't configured");
        [self bailFromRegistrationProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeUnableToRegisterUnconfiguredSyncManager classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:self.applicationSyncManager];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationSyncManagerWillRemoveAllRemoteSyncData:) name:TICDSApplicationSyncManagerWillRemoveAllSyncDataNotification object:self.applicationSyncManager];

    [self postIncreaseActivityNotification];
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerDidBeginRegistering:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManagerDidBeginRegistering:self];
         }];
    }

    if ([self.applicationSyncManager state] == TICDSApplicationSyncManagerStateAbleToSync) {
        [self.registrationQueue setSuspended:NO];
    } else {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appSyncManagerDidRegister:) name:TICDSApplicationSyncManagerDidFinishRegisteringNotification object:self.applicationSyncManager];
    }

    NSError *anyError = nil;
    BOOL shouldContinue = [self startDocumentRegistrationProcess:&anyError];
    if (shouldContinue == NO) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Error registering: %@", anyError);
        [self bailFromRegistrationProcessWithError:anyError];
        return;
    }
}

#pragma mark - PRECONFIGURATION

- (void)preConfigureWithDelegate:(id <TICDSDocumentSyncManagerDelegate>)aDelegate appSyncManager:(TICDSApplicationSyncManager *)anAppSyncManager documentIdentifier:(NSString *)aDocumentIdentifier
{
    self.delegate = aDelegate;
    self.documentIdentifier = aDocumentIdentifier;
    self.shouldUseEncryption = [anAppSyncManager shouldUseEncryption];

    [self postIncreaseActivityNotification];

    NSError *anyError = nil;
    BOOL success = [self startDocumentConfigurationProcess:&anyError];

    if (success == NO) {
        if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToRegisterWithError:)]) {
            [self runOnMainQueueWithoutDeadlocking:^{
                 [(id)self.delegate documentSyncManager:self didFailToRegisterWithError:anyError];
             }];
        }
    }

    [self postDecreaseActivityNotification];
}

- (BOOL)startDocumentConfigurationProcess:(NSError **)outError
{
    // get the location of the helper file directory from the delegate, or create default location if necessary
    BOOL shouldContinue = [self checkForHelperFileDirectoryOrCreateIfNecessary:outError];

    if (shouldContinue == NO) {
        return NO;
    }

    self.configured = YES;

    return YES;
}

#pragma mark Helper File Directory

- (NSString *)applicationSupportDirectory
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *basePath = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
    return [basePath stringByAppendingPathComponent:[[NSProcessInfo processInfo] processName]];
}

- (NSURL *)defaultHelperFileLocation
{
    NSString *location = [[self applicationSupportDirectory] stringByAppendingPathComponent:TICDSDocumentsDirectoryName];
    location = [location stringByAppendingPathComponent:self.documentIdentifier];

    return [NSURL fileURLWithPath:location];
}

- (BOOL)createHelperFileDirectoryFileStructure:(NSError **)outError
{
    NSError *anyError = nil;

    NSString *unappliedSyncChangesPath = [[self.helperFileDirectoryLocation path] stringByAppendingPathComponent:TICDSUnappliedSyncChangesDirectoryName];
    BOOL success = YES;

    if ([self.fileManager fileExistsAtPath:unappliedSyncChangesPath] == NO) {
        success = [self.fileManager createDirectoryAtPath:unappliedSyncChangesPath withIntermediateDirectories:YES attributes:nil error:&anyError];
    }

    NSString *unappliedSyncCommandsPath = [[self.helperFileDirectoryLocation path] stringByAppendingPathComponent:TICDSUnappliedSyncCommandsDirectoryName];
    if (success && ![self.fileManager fileExistsAtPath:unappliedSyncCommandsPath]) {
        success = [self.fileManager createDirectoryAtPath:unappliedSyncCommandsPath withIntermediateDirectories:YES attributes:nil error:&anyError];
    }

    if (success == NO) {
        if (outError) {
            *outError = [TICDSError errorWithCode:TICDSErrorCodeFileManagerError underlyingError:anyError classAndMethod:__PRETTY_FUNCTION__];
        }
        return NO;
    }

    return YES;
}

- (BOOL)checkForHelperFileDirectoryOrCreateIfNecessary:(NSError **)outError
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfEachPhase, @"Asking delegate for location of helper file directory");
    NSURL *finalURL = nil;
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:helperFileDirectoryURLForDocumentWithIdentifier:description:userInfo:)]) {
        finalURL = [(id)self.delegate documentSyncManager:self helperFileDirectoryURLForDocumentWithIdentifier:self.documentIdentifier description:self.documentDescription userInfo:self.documentUserInfo];
    }

    TICDSLog(TICDSLogVerbosityEveryStep, @"Checking that delegate-provided helper file directory exists");

    if (finalURL && ![self.fileManager fileExistsAtPath:[finalURL path]]) {
        self.state = TICDSDocumentSyncManagerStateUnableToSyncBecauseDelegateProvidedHelperFileDirectoryDoesNotExist;
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Delegate-provided helper file directory does not exist");

        if (outError) {
            *outError = [TICDSError errorWithCode:TICDSErrorCodeHelperFileDirectoryDoesNotExist classAndMethod:__PRETTY_FUNCTION__];
        }
        return NO;
    }

    if (finalURL) {
        TICDSLog(TICDSLogVerbosityStartAndEndOfEachPhase, @"Delegate-provided helper file directory");

        self.helperFileDirectoryLocation = finalURL;
        return [self createHelperFileDirectoryFileStructure:outError];
    }

    // delegate did not provide a location for the helper files
    TICDSLog(TICDSLogVerbosityEveryStep, @"Delegate did not provide a location for helper files, so checking default location");

    self.helperFileDirectoryLocation = [self defaultHelperFileLocation];
    if ([self.fileManager fileExistsAtPath:[[self defaultHelperFileLocation] path]]) {
        TICDSLog(TICDSLogVerbosityEveryStep, @"Default helper file location exists, so using it");
        return [self createHelperFileDirectoryFileStructure:outError];
    }

    TICDSLog(TICDSLogVerbosityEveryStep, @"Default helper file location does not exist, so creating it");
    NSError *anyError = nil;
    BOOL success = [self.fileManager createDirectoryAtPath:[self.helperFileDirectoryLocation path] withIntermediateDirectories:YES attributes:nil error:&anyError];
    if (success == NO) {
        self.state = TICDSDocumentSyncManagerStateFailedToCreateDefaultHelperFileDirectory;
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to create default helper file directory: %@", anyError);

        if (outError) {
            *outError = [TICDSError errorWithCode:TICDSErrorCodeFileManagerError underlyingError:anyError classAndMethod:__PRETTY_FUNCTION__];
        }
        return NO;
    }

    success = [self createHelperFileDirectoryFileStructure:outError];
    if (success == NO) {
        return NO;
    }

    TICDSLog(TICDSLogVerbosityStartAndEndOfEachPhase, @"Created default helper file directory");

    return YES;
}

#pragma mark - ONE-SHOT REGISTRATION

- (void)registerWithDelegate:(id <TICDSDocumentSyncManagerDelegate>)aDelegate appSyncManager:(TICDSApplicationSyncManager *)anAppSyncManager managedObjectContext:(NSManagedObjectContext *)aContext documentIdentifier:(NSString *)aDocumentIdentifier description:(NSString *)aDocumentDescription userInfo:(NSDictionary *)someUserInfo
{
    // configure the document, if necessary
    NSError *anyError;
    BOOL shouldContinue = YES;

    [self postIncreaseActivityNotification];
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerDidBeginRegistering:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManagerDidBeginRegistering:self];
         }];
    }

    self.delegate = aDelegate;
    self.documentIdentifier = aDocumentIdentifier;
    self.shouldUseEncryption = [anAppSyncManager shouldUseEncryption];
    NSString *userDefaultsIntegrityKey = [TICDSUtilities userDefaultsKeyForIntegrityKeyForDocumentWithIdentifier:aDocumentIdentifier];
    NSString *integrityKey = [[NSUserDefaults standardUserDefaults] valueForKey:userDefaultsIntegrityKey];
    self.integrityKey = integrityKey;

    if (self.isConfigured == NO) {
        shouldContinue = [self startDocumentConfigurationProcess:&anyError];
    }

    if (shouldContinue == NO) {
        [self bailFromRegistrationProcessWithError:anyError];
        return;
    }

    self.state = TICDSDocumentSyncManagerStateRegistering;
    TICDSLog(TICDSLogVerbosityStartAndEndOfMainPhase, @"Starting to register document sync manager");

    self.primaryDocumentMOC = aContext;
    self.primaryDocumentMOC.documentSyncManager = self;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(synchronizedMOCDidSave:) name:NSManagedObjectContextDidSaveNotification object:self.primaryDocumentMOC];

    // setup the syncChangesMOC
    TICDSLog(TICDSLogVerbosityEveryStep, @"Creating SyncChangesMOC");

    [self addSyncChangesMocForDocumentMoc:self.primaryDocumentMOC];
    if ([self syncChangesMocForDocumentMoc:self.primaryDocumentMOC] == nil) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to create sync changes MOC");
        [self bailFromRegistrationProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeFailedToCreateSyncChangesMOC classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }
    TICDSLog(TICDSLogVerbosityEveryStep, @"Finished creating SyncChangesMOC");

    TICDSLog(TICDSLogVerbosityEveryStep, @"Registration Information:\n   Delegate: %@,\n   App Sync Manager: %@,\n   Document ID: %@,\n   Description: %@,\n   User Info: %@", aDelegate, anAppSyncManager, aDocumentIdentifier, aDocumentDescription, someUserInfo);
    self.applicationSyncManager = anAppSyncManager;
    self.documentDescription = aDocumentDescription;
    self.clientIdentifier = [anAppSyncManager clientIdentifier];
    self.documentUserInfo = someUserInfo;

    if ([anAppSyncManager state] == TICDSApplicationSyncManagerStateAbleToSync) {
        [self.registrationQueue setSuspended:NO];
    } else {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appSyncManagerDidRegister:) name:TICDSApplicationSyncManagerDidFinishRegisteringNotification object:anAppSyncManager];
    }

    shouldContinue = [self startDocumentRegistrationProcess:&anyError];
    if (shouldContinue == NO) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Error registering: %@", anyError);
        [self bailFromRegistrationProcessWithError:anyError];
        return;
    }
}

- (void)bailFromRegistrationProcessWithError:(NSError *)anError
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Bailing from registration process");
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToRegisterWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToRegisterWithError:anError];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (BOOL)startDocumentRegistrationProcess:(NSError **)outError
{
    TICDSDocumentRegistrationOperation *operation = [self documentRegistrationOperation];

    if (operation == nil) {
        if (outError) {
            *outError = [TICDSError errorWithCode:TICDSErrorCodeFailedToCreateOperationObject classAndMethod:__PRETTY_FUNCTION__];
        }

        return NO;
    }

    [operation setShouldUseEncryption:self.shouldUseEncryption];
    operation.documentIdentifier = self.documentIdentifier;
    [operation setIntegrityKey:self.integrityKey];
    [operation setClientIdentifier:self.clientIdentifier];
    [operation setClientDescription:[self.applicationSyncManager clientDescription]];
    [operation setDocumentDescription:self.documentDescription];
    [operation setDocumentUserInfo:self.documentUserInfo];

    [self.registrationQueue addOperation:operation];

    return YES;
}

#pragma mark Helper File Directory Deletion and Recreation

- (void)removeExistingHelperFileDirectory
{
    TICDSLog(TICDSLogVerbosityEveryStep, @"Removing existing helper file directory");

    NSError *anyError = nil;
    if ([self.fileManager fileExistsAtPath:[self.helperFileDirectoryLocation path]] && ![self.fileManager removeItemAtPath:[self.helperFileDirectoryLocation path] error:&anyError]) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to delete existing local helper files for this document, but not absolutely catastrophic, so continuing. Error: %@", anyError);
    }
}

- (void)removeThenRecreateExistingHelperFileDirectory
{
    [self removeExistingHelperFileDirectory];

    TICDSLog(TICDSLogVerbosityEveryStep, @"Recreating document helper file directory");
    NSError *anyError = nil;
    if ([self createHelperFileDirectoryFileStructure:&anyError] == NO) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to recreate helper file directory structure for this document, but probably related to a previous error so continuing. Error: %@", anyError);
    }
}

#pragma mark Asking if Should Create Remote Document File Structure

- (void)registrationOperationPausedToFindOutWhetherToCreateRemoteDocumentStructure:(TICDSDocumentRegistrationOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfEachPhase, @"Registration operation paused to find out whether to create document structure");

    if ([anOperation documentWasDeleted]) {
        TICDSLog(TICDSLogVerbosityEveryStep, @"Document was deleted, so deleting local helper files for this document");
        [self removeThenRecreateExistingHelperFileDirectory];
        if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didPauseRegistrationAsRemoteFileStructureWasDeletedForDocumentWithIdentifier:description:userInfo:)]) {
            [self runOnMainQueueWithoutDeadlocking:^{
                 [(id)self.delegate documentSyncManager:self didPauseRegistrationAsRemoteFileStructureWasDeletedForDocumentWithIdentifier:self.documentIdentifier description:self.documentDescription userInfo:self.documentUserInfo];
             }];
        }
    } else {
        if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didPauseRegistrationAsRemoteFileStructureDoesNotExistForDocumentWithIdentifier:description:userInfo:)]) {
            [self runOnMainQueueWithoutDeadlocking:^{
                 [(id)self.delegate documentSyncManager:self didPauseRegistrationAsRemoteFileStructureDoesNotExistForDocumentWithIdentifier:self.documentIdentifier description:self.documentDescription userInfo:self.documentUserInfo];
             }];
        }
    }

    [self postDecreaseActivityNotification];
}

- (void)registrationOperationResumedFollowingDocumentStructureCreationInstruction:(TICDSDocumentRegistrationOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfEachPhase, @"Registration operation resumed after finding out whether to create document structure");
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerDidContinueRegistering:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManagerDidContinueRegistering:self];
         }];
    }
    [self postIncreaseActivityNotification];
}

- (void)continueRegistrationByCreatingRemoteFileStructure:(BOOL)shouldCreateFileStructure
{
    // Just start the registration operation again
    [(TICDSDocumentRegistrationOperation *)[[self.registrationQueue operations] lastObject] setShouldCreateDocumentFileStructure:shouldCreateFileStructure];
    [(TICDSDocumentRegistrationOperation *)[[self.registrationQueue operations] lastObject] setPaused:NO];

    self.mustUploadStoreAfterRegistration = YES;
}

#pragma mark Alerting Delegate that Client Was Deleted From Document

- (void)registrationOperationDidDetermineThatClientHadPreviouslyBeenDeletedFromSynchronizingWithDocument:(TICDSDocumentRegistrationOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityEveryStep, @"Document was deleted, so deleting local helper files for this document");
    [self removeThenRecreateExistingHelperFileDirectory];

    TICDSLog(TICDSLogVerbosityEveryStep, @"Alerting delegate that client was deleted from synchronizing document");

    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerDidDetermineThatClientHadPreviouslyBeenDeletedFromSynchronizingWithDocument:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManagerDidDetermineThatClientHadPreviouslyBeenDeletedFromSynchronizingWithDocument:self];
         }];
    }
}

#pragma mark Operation Generation

- (TICDSDocumentRegistrationOperation *)documentRegistrationOperation
{
    return [[TICDSDocumentRegistrationOperation alloc] initWithDelegate:self];
}

#pragma mark Operation Communications

- (void)documentRegistrationOperationCompleted:(TICDSDocumentRegistrationOperation *)anOperation
{
    // Primary Registration Complete from Operation
    TICDSLog(TICDSLogVerbosityStartAndEndOfEachPhase, @"Document Registration Operation Completed");

    self.state = TICDSDocumentSyncManagerStateAbleToSync;
    TICDSLog(TICDSLogVerbosityStartAndEndOfMainPhase, @"Finished registering document sync manager");

    [[NSNotificationCenter defaultCenter] postNotificationName:TICDSDocumentSyncManagerDidRegisterSuccessfullyNotification object:self];

    // Set integrity key for delegate to store
    self.integrityKey = [anOperation integrityKey];

    NSString *userDefaultsIntegrityKey = [TICDSUtilities userDefaultsKeyForIntegrityKeyForDocumentWithIdentifier:self.documentIdentifier];
    [[NSUserDefaults standardUserDefaults] setValue:self.integrityKey forKey:userDefaultsIntegrityKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // Registration Complete
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerDidFinishRegistering:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManagerDidFinishRegistering:self];
         }];
    }
    [self postDecreaseActivityNotification];

    // Upload whole store if necessary
    TICDSLog(TICDSLogVerbosityEveryStep, @"Checking whether to upload whole store after registration");
    if (self.mustUploadStoreAfterRegistration) {
        TICDSLog(TICDSLogVerbosityEveryStep, @"Must upload store because this is the first time this document has been registered");
        [self startWholeStoreUploadProcess];
    } else if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerShouldUploadWholeStoreAfterDocumentRegistration:)] && [(id)self.delegate documentSyncManagerShouldUploadWholeStoreAfterDocumentRegistration:self]) {
        TICDSLog(TICDSLogVerbosityEveryStep, @"Delegate allowed whole store upload after registration");
        [self startWholeStoreUploadProcess];
    } else {
        TICDSLog(TICDSLogVerbosityEveryStep, @"Delegate denied whole store upload after registration");
    }

    self.shouldUseEncryption = [self.applicationSyncManager shouldUseEncryption];

    TICDSLog(TICDSLogVerbosityEveryStep, @"Resuming Operation Queues");
    for ( TICDSOperation *eachOperation in [self.otherTasksQueue operations]) {
        [eachOperation setShouldUseEncryption:self.shouldUseEncryption];
    }

    for ( TICDSOperation *eachOperation in [self.synchronizationQueue operations]) {
        [eachOperation setShouldUseEncryption:self.shouldUseEncryption];
    }

    [self.otherTasksQueue setSuspended:NO];

    if (self.mustUploadStoreAfterRegistration == NO) {
        // Don't resume sync queue until after store was uploaded
        [self.synchronizationQueue setSuspended:NO];
    } else {
        // Don't offer to clean-up if document was just created on remote
        return;
    }

    // Perform clean-up if necessary
    TICDSLog(TICDSLogVerbosityEveryStep, @"Asking delegate whether to vacuum unneeded files after registration");
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerShouldVacuumUnneededRemoteFilesAfterDocumentRegistration:)] && [(id)self.delegate documentSyncManagerShouldVacuumUnneededRemoteFilesAfterDocumentRegistration:self]) {
        TICDSLog(TICDSLogVerbosityEveryStep, @"Delegate allowed vacuum after registration");
        [self startVacuumProcess];
    } else {
        TICDSLog(TICDSLogVerbosityEveryStep, @"Delegate denied vacuum after registration");
    }
}

- (void)documentRegistrationOperationWasCancelled:(TICDSDocumentRegistrationOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Document Registration Operation was Cancelled");

    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToRegisterWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToRegisterWithError:[TICDSError errorWithCode:TICDSErrorCodeTaskWasCancelled classAndMethod:__PRETTY_FUNCTION__]];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)documentRegistrationOperation:(TICDSDocumentRegistrationOperation *)anOperation failedToCompleteWithError:(NSError *)anError
{
    self.state = TICDSDocumentSyncManagerStateNotYetRegistered;
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Document Registration Operation Failed to Complete with Error: %@", anError);
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToRegisterWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToRegisterWithError:anError];
         }];
    }
    [self postDecreaseActivityNotification];
}

#pragma mark - WHOLE STORE UPLOAD

- (void)initiateUploadOfWholeStore
{
    TICDSLog(TICDSLogVerbosityEveryStep, @"Manual initiation of whole store upload");

    [self startWholeStoreUploadProcess];
}

- (void)bailFromUploadProcessWithError:(NSError *)anError
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Bailing from whole store upload process");
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToUploadWholeStoreWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToUploadWholeStoreWithError:anError];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)startWholeStoreUploadProcess
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfMainPhase, @"Starting whole store upload process");
    [self postIncreaseActivityNotification];
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerDidBeginUploadingWholeStore:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManagerDidBeginUploadingWholeStore:self];
         }];
    }

    TICDSLog(TICDSLogVerbosityEveryStep, @"Checking to see if there are unsynchronized SyncChanges");
    NSError *anyError = nil;
    NSUInteger count = [TICDSSyncChange ti_numberOfObjectsInManagedObjectContext:[self syncChangesMocForDocumentMoc:self.primaryDocumentMOC] error:&anyError];
    if (anyError) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to count number of SyncChange objects: %@", anyError);
        [self bailFromUploadProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeCoreDataFetchError underlyingError:anyError classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }

    if (count > 0) {
        TICDSLog(TICDSLogVerbosityEveryStep, @"There are unsynchronized local Sync Changes so cannot upload whole store");
        [self bailFromUploadProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeWholeStoreCannotBeUploadedWhileThereAreUnsynchronizedSyncChanges classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }

    TICDSLog(TICDSLogVerbosityStartAndEndOfEachPhase, @"Asking delegate for URL of whole store to upload");
    NSURL *storeURL = nil;
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:URLForWholeStoreToUploadForDocumentWithIdentifier:description:userInfo:)]) {
        storeURL = [(id)self.delegate documentSyncManager:self URLForWholeStoreToUploadForDocumentWithIdentifier:self.documentIdentifier description:self.documentDescription userInfo:self.documentUserInfo];
    }

    if (storeURL == nil || [self.fileManager fileExistsAtPath:[storeURL path]] == NO) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Store does not exist at provided path");
        [self bailFromUploadProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeUnexpectedOrIncompleteFileLocationOrDirectoryStructure classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }

    TICDSWholeStoreUploadOperation *operation = [self wholeStoreUploadOperation];

    if (operation == nil) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to create whole store operation object");
        [self bailFromUploadProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeFailedToCreateOperationObject classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }

    [operation setShouldUseEncryption:self.shouldUseEncryption];
    [operation setLocalWholeStoreFileLocation:storeURL];

    [operation configureBackgroundApplicationContextForPrimaryManagedObjectContext:self.primaryDocumentMOC];

    NSString *appliedSyncChangeSetsFilePath = [self.helperFileDirectoryLocation path];
    appliedSyncChangeSetsFilePath = [appliedSyncChangeSetsFilePath stringByAppendingPathComponent:TICDSAppliedSyncChangeSetsFilename];

    [operation setLocalAppliedSyncChangeSetsFileLocation:[NSURL fileURLWithPath:appliedSyncChangeSetsFilePath]];

    [self.otherTasksQueue addOperation:operation];
}

#pragma mark Operation Generation

- (TICDSWholeStoreUploadOperation *)wholeStoreUploadOperation
{
    return [[TICDSWholeStoreUploadOperation alloc] initWithDelegate:self];
}

#pragma mark Operation Communications

- (void)wholeStoreUploadOperationCompleted:(TICDSWholeStoreUploadOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfEachPhase, @"Whole Store Upload Operation Completed");

    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerDidFinishUploadingWholeStore:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManagerDidFinishUploadingWholeStore:self];
         }];
    }
    [self postDecreaseActivityNotification];

    // Unsuspend the sync queue in the case that this was a required upload for a newly-registered document
    if (self.mustUploadStoreAfterRegistration) {
        [self.synchronizationQueue setSuspended:NO];
    }
}

- (void)wholeStoreUploadOperationWasCancelled:(TICDSWholeStoreUploadOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Whole Store Upload Operation was Cancelled");

    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToUploadWholeStoreWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToUploadWholeStoreWithError:[TICDSError errorWithCode:TICDSErrorCodeTaskWasCancelled classAndMethod:__PRETTY_FUNCTION__]];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)wholeStoreUploadOperation:(TICDSDocumentRegistrationOperation *)anOperation failedToCompleteWithError:(NSError *)anError
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Whole Store Upload Operation Failed to Complete with Error: %@", anError);
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToUploadWholeStoreWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToUploadWholeStoreWithError:anError];
         }];
    }
    [self postDecreaseActivityNotification];
}

#pragma mark - WHOLE STORE DOWNLOAD

- (void)initiateDownloadOfWholeStore
{
    TICDSLog(TICDSLogVerbosityEveryStep, @"Manual initiation of whole store download");
    [self startWholeStoreDownloadProcess];
}

- (void)bailFromDownloadProcessWithError:(NSError *)anError
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Bailing from whole store download process");
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToDownloadWholeStoreWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToDownloadWholeStoreWithError:anError];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)bailFromDownloadPostProcessingWithFileManagerError:(NSError *)anError
{
    [self bailFromDownloadProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeFileManagerError underlyingError:anError classAndMethod:__PRETTY_FUNCTION__]];
    [self postDecreaseActivityNotification];
}

- (void)startWholeStoreDownloadProcess
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfMainPhase, @"Starting to download whole store");
    [self postIncreaseActivityNotification];
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerDidBeginDownloadingWholeStore:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManagerDidBeginDownloadingWholeStore:self];
         }];
    }

    // Set download to go to a temporary location
    NSString *temporaryPath = [NSTemporaryDirectory () stringByAppendingPathComponent:TICDSFrameworkName];
    temporaryPath = [temporaryPath stringByAppendingPathComponent:self.documentIdentifier];

    NSError *anyError = nil;
    BOOL success = [self.fileManager createDirectoryAtPath:temporaryPath withIntermediateDirectories:YES attributes:nil error:&anyError];
    if (success == NO) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to create temporary directory for whole store download: %@", anyError);

        [self bailFromDownloadProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeFileManagerError underlyingError:anyError classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }

    TICDSWholeStoreDownloadOperation *operation = [self wholeStoreDownloadOperation];

    if (operation == nil) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to create whole store download operation");
        [self bailFromDownloadProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeFailedToCreateOperationObject classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }

    [operation setShouldUseEncryption:self.shouldUseEncryption];

    NSString *wholeStoreFilePath = [temporaryPath stringByAppendingPathComponent:TICDSWholeStoreFilename];
    NSString *appliedSyncChangesFilePath = [temporaryPath stringByAppendingPathComponent:TICDSAppliedSyncChangeSetsFilename];

    [operation setLocalWholeStoreFileLocation:[NSURL fileURLWithPath:wholeStoreFilePath]];
    [operation setLocalAppliedSyncChangeSetsFileLocation:[NSURL fileURLWithPath:appliedSyncChangesFilePath]];

    [operation setClientIdentifier:self.clientIdentifier];

    [self.otherTasksQueue addOperation:operation];
}

#pragma mark Operation Generation

- (TICDSWholeStoreDownloadOperation *)wholeStoreDownloadOperation
{
    return [[TICDSWholeStoreDownloadOperation alloc] initWithDelegate:self];
}

#pragma mark Operation Communications

- (void)wholeStoreDownloadOperationCompleted:(TICDSWholeStoreDownloadOperation *)anOperation
{
    NSError *anyError = nil;
    BOOL success = YES;

    NSURL *finalWholeStoreLocation = nil;
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerURLForDownloadedStore:)]) {
        finalWholeStoreLocation = [(id)self.delegate documentSyncManagerURLForDownloadedStore:self];
    }

    if (finalWholeStoreLocation == nil) {
        NSPersistentStoreCoordinator *psc = [self.primaryDocumentMOC persistentStoreCoordinator];

        finalWholeStoreLocation = [psc URLForPersistentStore:[[psc persistentStores] lastObject]];
    }

    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:willReplaceStoreWithDownloadedStoreAtURL:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self willReplaceStoreWithDownloadedStoreAtURL:finalWholeStoreLocation];
         }];
    }

    // Remove old WholeStore
    if ([self.fileManager fileExistsAtPath:[finalWholeStoreLocation path]] && ![self.fileManager removeItemAtPath:[finalWholeStoreLocation path] error:&anyError]) {
        [self bailFromDownloadPostProcessingWithFileManagerError:anyError];
        return;
    }

    // Move downloaded WholeStore
    success = [self.fileManager moveItemAtPath:[[anOperation localWholeStoreFileLocation] path] toPath:[finalWholeStoreLocation path] error:&anyError];
    if (success == NO) {
        [self bailFromDownloadPostProcessingWithFileManagerError:anyError];
        return;
    }

    // Remove old AppliedSyncChanges
    if ([self.fileManager fileExistsAtPath:self.localAppliedSyncChangesFilePath] && ![self.fileManager removeItemAtPath:self.localAppliedSyncChangesFilePath error:&anyError]) {
        [self bailFromDownloadPostProcessingWithFileManagerError:anyError];
        return;
    }

    // Move newly downloaded AppliedSyncChanges
    if ([self.fileManager fileExistsAtPath:[[anOperation localAppliedSyncChangeSetsFileLocation] path]] && ![self.fileManager moveItemAtPath:[[anOperation localAppliedSyncChangeSetsFileLocation] path] toPath:self.localAppliedSyncChangesFilePath error:&anyError]) {
        [self bailFromDownloadPostProcessingWithFileManagerError:anyError];
        return;
    }

    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didReplaceStoreWithDownloadedStoreAtURL:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didReplaceStoreWithDownloadedStoreAtURL:finalWholeStoreLocation];
         }];
    }

    TICDSLog(TICDSLogVerbosityEveryStep, @"Updating local integrity key to match newly-downloaded store");
    self.integrityKey = [anOperation integrityKey];
    NSString *userDefaultsIntegrityKey = [TICDSUtilities userDefaultsKeyForIntegrityKeyForDocumentWithIdentifier:self.documentIdentifier];
    [[NSUserDefaults standardUserDefaults] setValue:self.integrityKey forKey:userDefaultsIntegrityKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    TICDSLog(TICDSLogVerbosityStartAndEndOfMainPhase, @"Whole Store Download complete");
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerDidFinishDownloadingWholeStore:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManagerDidFinishDownloadingWholeStore:self];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)wholeStoreDownloadOperationWasCancelled:(TICDSWholeStoreDownloadOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Whole Store Download operation was cancelled");
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToDownloadWholeStoreWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToDownloadWholeStoreWithError:[TICDSError errorWithCode:TICDSErrorCodeTaskWasCancelled classAndMethod:__PRETTY_FUNCTION__]];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)wholeStoreDownloadOperation:(TICDSWholeStoreDownloadOperation *)anOperation failedToCompleteWithError:(NSError *)anError
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Whole Store Download operation failed to complete with error: %@", anError);
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToDownloadWholeStoreWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToDownloadWholeStoreWithError:anError];
         }];
    }
    [self postDecreaseActivityNotification];
}

#pragma mark - SYNCHRONIZATION

- (void)initiateSynchronization
{
    TICDSLog(TICDSLogVerbosityEveryStep, @"Manual initiation of synchronization");

    [self startPreSynchronizationProcess];
}

- (void)cancelSynchronization
{
    [self.synchronizationQueue cancelAllOperations];
}

- (void)bailFromSynchronizationProcessWithError:(NSError *)anError
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Bailing from synchronization process");
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToSynchronizeWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToSynchronizeWithError:anError];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)startPreSynchronizationProcess
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfMainPhase, @"Starting pre-synchronization process");
    [self postIncreaseActivityNotification];
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerDidBeginSynchronizing:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
            [(id)self.delegate documentSyncManagerDidBeginSynchronizing:self];
        }];
    }
    
    [self moveUnsynchronizedSyncChangesToMergeLocation];
    
    TICDSPreSynchronizationOperation *operation = [self preSynchronizationOperation];
    
    if (operation == nil) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to create pre-synchronization operation object");
        [self bailFromSynchronizationProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeFailedToCreateOperationObject classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }
    
    [operation setShouldUseEncryption:self.shouldUseEncryption];
    [operation setClientIdentifier:self.clientIdentifier];
    [operation setIntegrityKey:self.integrityKey];
    
    // Set locations of files
    [operation setAppliedSyncChangeSetsFileLocation:[NSURL fileURLWithPath:[[self.helperFileDirectoryLocation path] stringByAppendingPathComponent:TICDSAppliedSyncChangeSetsFilename]]];
    [operation setUnappliedSyncChangesDirectoryLocation:[NSURL fileURLWithPath:[[self.helperFileDirectoryLocation path] stringByAppendingPathComponent:TICDSUnappliedSyncChangesDirectoryName]]];
    [operation setUnappliedSyncChangeSetsFileLocation:[NSURL fileURLWithPath:[[self.helperFileDirectoryLocation path] stringByAppendingPathComponent:TICDSUnappliedChangeSetsFilename]]];
    
    [self.synchronizationQueue addOperation:operation];
}

- (void)startSynchronizationProcess
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfMainPhase, @"Starting synchronization process");
    [self postIncreaseActivityNotification];
    
    TICDSSynchronizationOperation *operation = [self synchronizationOperation];
    
    if (operation == nil) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to create synchronization operation object");
        [self bailFromSynchronizationProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeFailedToCreateOperationObject classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }
    
    [operation setShouldUseEncryption:self.shouldUseEncryption];
    [operation setClientIdentifier:self.clientIdentifier];
    
    // Set location of sync changes to merge file
    NSURL *syncChangesToMergeLocation = nil;
    if ([self.fileManager fileExistsAtPath:self.syncChangesBeingSynchronizedStorePath]) {
        syncChangesToMergeLocation = [NSURL fileURLWithPath:self.syncChangesBeingSynchronizedStorePath];
    }
    [operation setLocalSyncChangesToMergeURL:syncChangesToMergeLocation];
    
    // Set locations of files
    [operation setAppliedSyncChangeSetsFileLocation:[NSURL fileURLWithPath:[[self.helperFileDirectoryLocation path] stringByAppendingPathComponent:TICDSAppliedSyncChangeSetsFilename]]];
    [operation setUnappliedSyncChangesDirectoryLocation:[NSURL fileURLWithPath:[[self.helperFileDirectoryLocation path] stringByAppendingPathComponent:TICDSUnappliedSyncChangesDirectoryName]]];
    [operation setUnappliedSyncChangeSetsFileLocation:[NSURL fileURLWithPath:[[self.helperFileDirectoryLocation path] stringByAppendingPathComponent:TICDSUnappliedChangeSetsFilename]]];
    
    // Set background context
    [operation configureBackgroundApplicationContextForPrimaryManagedObjectContext:self.primaryDocumentMOC];
    
    [self.synchronizationQueue addOperation:operation];
}

- (void)startPostSynchronizationProcess
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfMainPhase, @"Starting post-synchronization process");
    [self postIncreaseActivityNotification];

    TICDSPostSynchronizationOperation *operation = [self postSynchronizationOperation];
    
    if (operation == nil) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to create post-synchronization operation object");
        [self bailFromSynchronizationProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeFailedToCreateOperationObject classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }
    
    [operation setShouldUseEncryption:self.shouldUseEncryption];
    [operation setClientIdentifier:self.clientIdentifier];
    
    // Set location of sync changes to merge file
    NSURL *syncChangesToMergeLocation = nil;
    if ([self.fileManager fileExistsAtPath:self.syncChangesBeingSynchronizedStorePath]) {
        syncChangesToMergeLocation = [NSURL fileURLWithPath:self.syncChangesBeingSynchronizedStorePath];
    }
    [operation setLocalSyncChangesToMergeURL:syncChangesToMergeLocation];
    
    // Set locations of files
    [operation setAppliedSyncChangeSetsFileLocation:[NSURL fileURLWithPath:[[self.helperFileDirectoryLocation path] stringByAppendingPathComponent:TICDSAppliedSyncChangeSetsFilename]]];
    [operation setLocalRecentSyncFileLocation:[NSURL fileURLWithPath:[[[self.helperFileDirectoryLocation path] stringByAppendingPathComponent:self.clientIdentifier] stringByAppendingPathExtension:TICDSRecentSyncFileExtension]]];
    
    [self.synchronizationQueue addOperation:operation];
}

- (void)moveUnsynchronizedSyncChangesToMergeLocation
{
    // check whether there's an existing set of sync changes to merge left over from a previous error
    if ([self.fileManager fileExistsAtPath:self.syncChangesBeingSynchronizedStorePath]) {
        TICDSLog(TICDSLogVerbosityEveryStep, @"A SyncChangesBeingSynchronized.syncchg file already exists from a previous failed sync, so using it for this synchronization process. The most recent local sync changes won't be synchronized.");
        return;
    }

    TICDSLog(TICDSLogVerbosityEveryStep, @"Checking if there are local sync changes to merge and push");
    NSError *anyError = nil;
    NSArray *syncChanges = [TICDSSyncChange ti_allObjectsInManagedObjectContext:[self syncChangesMocForDocumentMoc:self.primaryDocumentMOC] error:&anyError];

    if (syncChanges == nil) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to fetch local sync changes");
        [self bailFromSynchronizationProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeCoreDataFetchError underlyingError:anyError classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }

    if ([syncChanges count] < 1) {
        TICDSLog(TICDSLogVerbosityEveryStep, @"No local sync changes need to be pushed for this sync operation");
        return;
    }

    TICDSLog(TICDSLogVerbosityEveryStep, @"Moving UnsynchronizedSyncChanges to SyncChangesBeingSynchronized");

    self.coreDataFactory = nil;
    [self.syncChangesMOCs setValue:nil forKey:[self keyForContext:self.primaryDocumentMOC]];

    // move UnsynchronizedSyncChanges file to SyncChangesBeingSynchronized
    BOOL success = [self.fileManager moveItemAtPath:self.unsynchronizedSyncChangesStorePath toPath:self.syncChangesBeingSynchronizedStorePath error:&anyError];

    if (success == NO) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to move UnsynchronizedSyncChanges.syncchg to SyncChangesBeingSynchronized.syncchg");
        [self bailFromSynchronizationProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeFileManagerError underlyingError:anyError classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }

    // setup the syncChangesMOC
    TICDSLog(TICDSLogVerbosityEveryStep, @"Re-Creating SyncChangesMOC");
    [self addSyncChangesMocForDocumentMoc:self.primaryDocumentMOC];
    if ([self syncChangesMocForDocumentMoc:self.primaryDocumentMOC] == nil) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to create sync changes MOC");
        [self bailFromSynchronizationProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeFailedToCreateSyncChangesMOC classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }
    TICDSLog(TICDSLogVerbosityEveryStep, @"Finished creating SyncChangesMOC");
}

- (void)synchronizationOperation:(TICDSSynchronizationOperation *)anOperation processedChangeNumber:(NSNumber *)changeNumber outOfTotalChangeCount:(NSNumber *)totalChangeCount fromClientWithID:(NSString *)clientIdentifier
{
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:processedChangeNumber:outOfTotalChangeCount:fromClientWithID:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self processedChangeNumber:changeNumber outOfTotalChangeCount:totalChangeCount fromClientWithID:clientIdentifier];
         }];
    }
}

#pragma mark Conflict Resolution

- (void)synchronizationOperation:(TICDSSynchronizationOperation *)anOperation pausedToDetermineResolutionOfConflict:(id)aConflict
{
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didPauseSynchronizationAwaitingResolutionOfSyncConflict:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didPauseSynchronizationAwaitingResolutionOfSyncConflict:aConflict];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)synchronizationOperationResumedFollowingResolutionOfConflict:(TICDSSynchronizationOperation *)anOperation
{
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerDidContinueSynchronizing:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManagerDidContinueSynchronizing:self];
         }];
    }
    [self postIncreaseActivityNotification];
}

- (void)continueSynchronizationByResolvingConflictWithResolutionType:(TICDSSyncConflictResolutionType)conflictResolutionType
{
    if (self.synchronizationQueue.operations.count == 0) {
        return;
    }
    
    TICDSSynchronizationOperation *operation = [[self.synchronizationQueue operations] objectAtIndex:0];
    operation.mostRecentConflictResolutionType = conflictResolutionType;
    operation.paused = NO;
}

#pragma mark Operation Generation

- (TICDSPreSynchronizationOperation *)preSynchronizationOperation
{
    return [[TICDSPreSynchronizationOperation alloc] initWithDelegate:self];
}

- (TICDSSynchronizationOperation *)synchronizationOperation
{
    return [[TICDSSynchronizationOperation alloc] initWithDelegate:self];
}

- (TICDSPostSynchronizationOperation *)postSynchronizationOperation
{
    return [[TICDSPostSynchronizationOperation alloc] initWithDelegate:self];
}

#pragma mark Operation Communications
#pragma Success
- (void)preSynchronizationOperationCompleted:(TICDSPreSynchronizationOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfEachPhase, @"Pre-Synchronization Operation Completed");
    
    [self startSynchronizationProcess];
    [self postDecreaseActivityNotification];
}

- (void)synchronizationOperationCompleted:(TICDSSynchronizationOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfEachPhase, @"Synchronization Operation Completed");
    
    if ([[anOperation synchronizationWarnings] count] > 0) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Synchronization encountered warnings: \n%@", [anOperation synchronizationWarnings]);
        if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didEncounterWarningsWhileSynchronizing:)]) {
            [self runOnMainQueueWithoutDeadlocking:^{
                [(id)self.delegate documentSyncManager:self didEncounterWarningsWhileSynchronizing:[anOperation synchronizationWarnings]];
            }];
        }
    }

    [self startPostSynchronizationProcess];
    [self postDecreaseActivityNotification];
}

- (void)postSynchronizationOperationCompleted:(TICDSPostSynchronizationOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfEachPhase, @"Post-Synchronization Operation Completed");
    
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerDidFinishSynchronizing:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
            [(id)self.delegate documentSyncManagerDidFinishSynchronizing:self];
        }];
    }
    [self postDecreaseActivityNotification];
}

#pragma Cancellation
- (void)preSynchronizationOperationWasCancelled:(TICDSPreSynchronizationOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Pre-Synchronization Operation was Cancelled");
    
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToSynchronizeWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
            [(id)self.delegate documentSyncManager:self didFailToSynchronizeWithError:[TICDSError errorWithCode:TICDSErrorCodeTaskWasCancelled classAndMethod:__PRETTY_FUNCTION__]];
        }];
    }
    [self postDecreaseActivityNotification];
}

- (void)synchronizationOperationWasCancelled:(TICDSSynchronizationOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Synchronization Operation was Cancelled");
    
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToSynchronizeWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
            [(id)self.delegate documentSyncManager:self didFailToSynchronizeWithError:[TICDSError errorWithCode:TICDSErrorCodeTaskWasCancelled classAndMethod:__PRETTY_FUNCTION__]];
        }];
    }
    [self postDecreaseActivityNotification];
}

- (void)postSynchronizationOperationWasCancelled:(TICDSPostSynchronizationOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Post-Synchronization Operation was Cancelled");
    
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToSynchronizeWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
            [(id)self.delegate documentSyncManager:self didFailToSynchronizeWithError:[TICDSError errorWithCode:TICDSErrorCodeTaskWasCancelled classAndMethod:__PRETTY_FUNCTION__]];
        }];
    }
    [self postDecreaseActivityNotification];
}

#pragma Failure
- (void)preSynchronizationOperation:(TICDSPreSynchronizationOperation *)anOperation failedToCompleteWithError:(NSError *)anError
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Pre-Synchronization Operation Failed to Complete with Error: %@", anError);
    
    if ([anError code] == TICDSErrorCodeSynchronizationFailedBecauseIntegrityKeysDoNotMatch) {
        TICDSLog(TICDSLogVerbosityEveryStep, @"Removing helper file directory because integrity keys do not match");
        [self removeThenRecreateExistingHelperFileDirectory];
    }
    
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToSynchronizeWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
            [(id)self.delegate documentSyncManager:self didFailToSynchronizeWithError:anError];
        }];
    }
    [self postDecreaseActivityNotification];
}

- (void)synchronizationOperation:(TICDSSynchronizationOperation *)anOperation failedToCompleteWithError:(NSError *)anError
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Synchronization Operation Failed to Complete with Error: %@", anError);
    
    if ([anError code] == TICDSErrorCodeSynchronizationFailedBecauseIntegrityKeysDoNotMatch) {
        TICDSLog(TICDSLogVerbosityEveryStep, @"Removing helper file directory because integrity keys do not match");
        [self removeThenRecreateExistingHelperFileDirectory];
    }
    
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToSynchronizeWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
            [(id)self.delegate documentSyncManager:self didFailToSynchronizeWithError:anError];
        }];
    }
    [self postDecreaseActivityNotification];
}

- (void)postSynchronizationOperation:(TICDSPostSynchronizationOperation *)anOperation failedToCompleteWithError:(NSError *)anError
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Post-Synchronization Operation Failed to Complete with Error: %@", anError);
    
    if ([anError code] == TICDSErrorCodeSynchronizationFailedBecauseIntegrityKeysDoNotMatch) {
        TICDSLog(TICDSLogVerbosityEveryStep, @"Removing helper file directory because integrity keys do not match");
        [self removeThenRecreateExistingHelperFileDirectory];
    }
    
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToSynchronizeWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
            [(id)self.delegate documentSyncManager:self didFailToSynchronizeWithError:anError];
        }];
    }
    [self postDecreaseActivityNotification];
}

#pragma mark - VACUUMING

- (void)initiateVacuumOfUnneededRemoteFiles
{
    TICDSLog(TICDSLogVerbosityEveryStep, @"Manual initiation of vacuum process");

    [self startVacuumProcess];
}

- (void)bailFromVacuumProcessWithError:(NSError *)anError
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Bailing from vacuum process");
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToVacuumUnneededRemoteFilesWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToVacuumUnneededRemoteFilesWithError:anError];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)startVacuumProcess
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfMainPhase, @"Starting vacuum process to remove unneeded files from the remote");
    [self postIncreaseActivityNotification];
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerDidBeginVacuumingUnneededRemoteFiles:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManagerDidBeginVacuumingUnneededRemoteFiles:self];
         }];
    }

    TICDSVacuumOperation *operation = [self vacuumOperation];

    if (operation == nil) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to create vacuum operation object");
        [self bailFromVacuumProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeFailedToCreateOperationObject classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }

    [operation setShouldUseEncryption:self.shouldUseEncryption];

    [self.otherTasksQueue addOperation:operation];
}

#pragma mark Operation Generation

- (TICDSVacuumOperation *)vacuumOperation
{
    return [[TICDSVacuumOperation alloc] initWithDelegate:self];
}

#pragma mark Operation Communications

- (void)vacuumOperationCompleted:(TICDSVacuumOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfEachPhase, @"Vacuum Operation Completed");

    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerDidFinishVacuumingUnneededRemoteFiles:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManagerDidFinishVacuumingUnneededRemoteFiles:self];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)vacuumOperationWasCancelled:(TICDSVacuumOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Vacuum Operation was Cancelled");

    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToVacuumUnneededRemoteFilesWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToVacuumUnneededRemoteFilesWithError:[TICDSError errorWithCode:TICDSErrorCodeTaskWasCancelled classAndMethod:__PRETTY_FUNCTION__]];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)vacuumOperation:(TICDSVacuumOperation *)anOperation failedToCompleteWithError:(NSError *)anError
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Vacuum Operation Failed to Complete with Error: %@", anError);
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToVacuumUnneededRemoteFilesWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToVacuumUnneededRemoteFilesWithError:anError];
         }];
    }
    [self postDecreaseActivityNotification];
}

#pragma mark - REGISTERED CLIENT INFORMATION

- (void)requestInformationForAllRegisteredDevices
{
    TICDSLog(TICDSLogVerbosityEveryStep, @"Manual initiation of registered device information request");

    [self startRegisteredDevicesInformationProcess];
}

- (void)bailFromRegisteredDevicesInformationProcessWithError:(NSError *)anError
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Bailing from device information request");
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToFetchInformationForAllRegisteredDevicesWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToFetchInformationForAllRegisteredDevicesWithError:anError];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)startRegisteredDevicesInformationProcess
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfMainPhase, @"Starting process to fetch information on all devices registered to synchronize this document");
    [self postIncreaseActivityNotification];
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManagerDidBeginFetchingInformationForAllRegisteredDevices:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManagerDidBeginFetchingInformationForAllRegisteredDevices:self];
         }];
    }

    TICDSListOfDocumentRegisteredClientsOperation *operation = [self listOfDocumentRegisteredClientsOperation];

    if (operation == nil) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to create registered devices operation object");
        [self bailFromRegisteredDevicesInformationProcessWithError:[TICDSError errorWithCode:TICDSErrorCodeFailedToCreateOperationObject classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }

    [operation setShouldUseEncryption:self.shouldUseEncryption];

    [self.otherTasksQueue addOperation:operation];
}

#pragma mark Operation Generation

- (TICDSListOfDocumentRegisteredClientsOperation *)listOfDocumentRegisteredClientsOperation
{
    return [[TICDSListOfDocumentRegisteredClientsOperation alloc] initWithDelegate:self];
}

#pragma mark Operation Communications

- (void)registeredClientsOperationCompleted:(TICDSListOfDocumentRegisteredClientsOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfEachPhase, @"Registered Device Information Operation Completed");

    NSDictionary *information = [anOperation deviceInfoDictionaries];

    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFinishFetchingInformationForAllRegisteredDevices:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFinishFetchingInformationForAllRegisteredDevices:information];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)registeredClientsOperationWasCancelled:(TICDSListOfDocumentRegisteredClientsOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Registered Device Information Operation was Cancelled");

    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToFetchInformationForAllRegisteredDevicesWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToFetchInformationForAllRegisteredDevicesWithError:[TICDSError errorWithCode:TICDSErrorCodeTaskWasCancelled classAndMethod:__PRETTY_FUNCTION__]];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)registeredClientsOperation:(TICDSListOfDocumentRegisteredClientsOperation *)anOperation failedToCompleteWithError:(NSError *)anError
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Registered Device Information Operation Failed to Complete with Error: %@", anError);
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToFetchInformationForAllRegisteredDevicesWithError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToFetchInformationForAllRegisteredDevicesWithError:anError];
         }];
    }
    [self postDecreaseActivityNotification];
}

#pragma mark - DELETION OF CLIENT DATA FROM A DOCUMENT

- (void)deleteDocumentSynchronizationDataForClientWithIdentifier:(NSString *)anIdentifier
{
    TICDSLog(TICDSLogVerbosityEveryStep, @"Manual initiation of request to delete document synchronization data for client %@", anIdentifier);

    [self startClientDeletionProcessForClient:anIdentifier];
}

- (void)bailFromClientDeletionProcessForClient:(NSString *)anIdentifier withError:(NSError *)anError
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Bailing from client device deletion from document synchronization request");
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToDeleteSynchronizationDataFromDocumentForClientWithIdentifier:withError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToDeleteSynchronizationDataFromDocumentForClientWithIdentifier:anIdentifier withError:anError];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)startClientDeletionProcessForClient:(NSString *)anIdentifier
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfMainPhase, @"Starting process to delete synchronization data from the document for client %@", anIdentifier);
    [self postIncreaseActivityNotification];
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didBeginDeletingSynchronizationDataFromDocumentForClientWithIdentifier:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didBeginDeletingSynchronizationDataFromDocumentForClientWithIdentifier:anIdentifier];
         }];
    }

    TICDSDocumentClientDeletionOperation *operation = [self documentClientDeletionOperation];

    if (operation == nil) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Failed to create document client deletion operation object");
        [self bailFromClientDeletionProcessForClient:anIdentifier withError:[TICDSError errorWithCode:TICDSErrorCodeFailedToCreateOperationObject classAndMethod:__PRETTY_FUNCTION__]];
        return;
    }

    [operation setIdentifierOfClientToBeDeleted:anIdentifier];
    [operation setShouldUseEncryption:self.shouldUseEncryption];

    [self.otherTasksQueue addOperation:operation];
}

#pragma mark Operation Generation

- (TICDSDocumentClientDeletionOperation *)documentClientDeletionOperation
{
    return [[TICDSDocumentClientDeletionOperation alloc] initWithDelegate:self];
}

#pragma mark Operation Communications

- (void)documentClientDeletionOperationCompleted:(TICDSDocumentClientDeletionOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityStartAndEndOfEachPhase, @"Document Client Deletion Operation Completed");

    NSString *clientIdentifier = [anOperation identifierOfClientToBeDeleted];

    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFinishDeletingSynchronizationDataFromDocumentForClientWithIdentifier:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFinishDeletingSynchronizationDataFromDocumentForClientWithIdentifier:clientIdentifier];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)documentClientDeletionOperationWasCancelled:(TICDSDocumentClientDeletionOperation *)anOperation
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Document Client Deletion Operation was Cancelled");

    NSString *clientIdentifier = [anOperation identifierOfClientToBeDeleted];

    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToDeleteSynchronizationDataFromDocumentForClientWithIdentifier:withError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToDeleteSynchronizationDataFromDocumentForClientWithIdentifier:clientIdentifier withError:[TICDSError errorWithCode:TICDSErrorCodeTaskWasCancelled classAndMethod:__PRETTY_FUNCTION__]];
         }];
    }
    [self postDecreaseActivityNotification];
}

- (void)documentClientDeletionOperation:(TICDSDocumentClientDeletionOperation *)anOperation failedToCompleteWithError:(NSError *)anError
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"Document Client Deletion Operation Failed to Complete with Error: %@", anError);
    NSString *clientIdentifier = [anOperation identifierOfClientToBeDeleted];

    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToDeleteSynchronizationDataFromDocumentForClientWithIdentifier:withError:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFailToDeleteSynchronizationDataFromDocumentForClientWithIdentifier:clientIdentifier withError:anError];
         }];
    }
    [self postDecreaseActivityNotification];
}

#pragma mark - ADDITIONAL MANAGED OBJECT CONTEXTS

- (void)addManagedObjectContext:(NSManagedObjectContext *)aContext
{
    TICDSLog(TICDSLogVerbosityEveryStep, @"Adding SyncChanges MOC for document context: %@", aContext);
    [self addSyncChangesMocForDocumentMoc:aContext];
}

- (NSManagedObjectContext *)addSyncChangesMocForDocumentMoc:(NSManagedObjectContext *)documentManagedObjectContext
{
    NSManagedObjectContext *syncChangesManagedObjectContext = [self.syncChangesMOCs valueForKey:[self keyForContext:documentManagedObjectContext]];

    if (syncChangesManagedObjectContext != nil) {
        return syncChangesManagedObjectContext;
    }

    [documentManagedObjectContext setDocumentSyncManager:self];

    NSPersistentStoreCoordinator *persistentStoreCoordinator = [self.coreDataFactory persistentStoreCoordinator];
    if (persistentStoreCoordinator == nil) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"We got a nil NSPersistentStoreCoordinator back from the Core Data Factory, trying to reset the factory.");
        self.coreDataFactory = nil;
        persistentStoreCoordinator = [self.coreDataFactory persistentStoreCoordinator];
        if (persistentStoreCoordinator == nil) {
            TICDSLog(TICDSLogVerbosityErrorsOnly, @"Resetting the Core Data Factory didn't help, bailing from this method.");
            return nil;
        }
    }

    syncChangesManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSConfinementConcurrencyType];
    syncChangesManagedObjectContext.persistentStoreCoordinator = persistentStoreCoordinator;

    [self.syncChangesMOCs setValue:syncChangesManagedObjectContext forKey:[self keyForContext:documentManagedObjectContext]];

    return syncChangesManagedObjectContext;
}

- (NSManagedObjectContext *)syncChangesMocForDocumentMoc:(NSManagedObjectContext *)documentManagedObjectContext
{
    NSManagedObjectContext *syncChangesManagedObjectContext = [self.syncChangesMOCs valueForKey:[self keyForContext:documentManagedObjectContext]];

    if (syncChangesManagedObjectContext == nil) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"SyncChanges MOC was requested for a managed object context that hasn't yet been added, so adding it before proceeding");

        syncChangesManagedObjectContext = [self addSyncChangesMocForDocumentMoc:documentManagedObjectContext];
        if (syncChangesManagedObjectContext == nil) {
            NSLog(@"%s There was a problem getting the sync changes MOC for the document MOC.", __PRETTY_FUNCTION__);
        }
    }

    return syncChangesManagedObjectContext;
}

- (NSString *)keyForContext:(NSManagedObjectContext *)aContext
{
    return [NSString stringWithFormat:@"%p", aContext];
}

#pragma mark - MANAGED OBJECT CONTEXT DID SAVE BEHAVIOR

- (void)synchronizedMOCWillSave:(NSManagedObjectContext *)aMoc
{
    // Do anything here that's needed before the application context is saved
}

- (void)synchronizedMOCDidSave:(NSNotification *)notification
{
    NSManagedObjectContext *documentManagedObjectContext = notification.object;
    if (documentManagedObjectContext != self.primaryDocumentMOC) {
        NSLog(@"%s Processing a synchronizedMOCDidSave: method for a MOC that isn't the primary document MOC", __PRETTY_FUNCTION__);
        return;
    }
    
    TICDSLog(TICDSLogVerbosityStartAndEndOfMainPhase, @"MOC saved, so beginning post-save processing");
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didBeginProcessingSyncChangesAfterManagedObjectContextDidSave:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didBeginProcessingSyncChangesAfterManagedObjectContextDidSave:documentManagedObjectContext];
         }];
    }

    NSError *anyError = nil;
    BOOL success = NO;

    TICDSLog(TICDSLogVerbosityStartAndEndOfEachPhase, @"Sync Manager will save Sync Changes context");
    NSManagedObjectContext *syncChangesManagedObjectContext = [self syncChangesMocForDocumentMoc:documentManagedObjectContext];
    success = [syncChangesManagedObjectContext save:&anyError];

    if (success == NO) {
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Sync Manager failed to save Sync Changes context with error: %@", anyError);
        TICDSLog(TICDSLogVerbosityErrorsOnly, @"Sync Manager cannot continue processing any further, so bailing");
        if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFailToProcessSyncChangesAfterManagedObjectContextDidSave:withError:)]) {
            [self runOnMainQueueWithoutDeadlocking:^{
                 [(id)self.delegate documentSyncManager:self didFailToProcessSyncChangesAfterManagedObjectContextDidSave:documentManagedObjectContext withError:[TICDSError errorWithCode:TICDSErrorCodeFailedToSaveSyncChangesMOC underlyingError:anyError classAndMethod:__PRETTY_FUNCTION__]];
             }];
        }

        return;
    }

    TICDSLog(TICDSLogVerbosityStartAndEndOfEachPhase, @"Sync Manager saved Sync Changes context successfully");
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didFinishProcessingSyncChangesAfterManagedObjectContextDidSave:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didFinishProcessingSyncChangesAfterManagedObjectContextDidSave:documentManagedObjectContext];
         }];
    }

    TICDSLog(TICDSLogVerbosityEveryStep, @"Asking delegate if we should sync after saving");
    BOOL shouldSync = [self ti_delegateRespondsToSelector:@selector(documentSyncManager:shouldBeginSynchronizingAfterManagedObjectContextDidSave:)] && [(id)self.delegate documentSyncManager:self shouldBeginSynchronizingAfterManagedObjectContextDidSave:documentManagedObjectContext];
    if (shouldSync == NO) {
        TICDSLog(TICDSLogVerbosityEveryStep, @"Delegate denied synchronization after saving");
        return;
    }

    TICDSLog(TICDSLogVerbosityEveryStep, @"Delegate allowed synchronization after saving");
    [self startPreSynchronizationProcess];
}

#pragma mark - NOTIFICATIONS

- (void)appSyncManagerDidRegister:(NSNotification *)aNotification
{
    self.shouldUseEncryption = [self.applicationSyncManager shouldUseEncryption];

    for ( TICDSOperation *eachOperation in [self.registrationQueue operations]) {
        [eachOperation setShouldUseEncryption:self.shouldUseEncryption];
    }

    for ( TICDSOperation *eachOperation in [self.synchronizationQueue operations]) {
        [eachOperation setShouldUseEncryption:self.shouldUseEncryption];
    }

    for ( TICDSOperation *eachOperation in [self.otherTasksQueue operations]) {
        [eachOperation setShouldUseEncryption:self.shouldUseEncryption];
    }

    [self.registrationQueue setSuspended:NO];
}

- (void)backgroundManagedObjectContextDidSave:(NSNotification *)aNotification
{
    if ([self ti_delegateRespondsToSelector:@selector(documentSyncManager:didMakeChangesToObjectsInBackgroundContextAndSaveWithNotification:)]) {
        [self runOnMainQueueWithoutDeadlocking:^{
             [(id)self.delegate documentSyncManager:self didMakeChangesToObjectsInBackgroundContextAndSaveWithNotification:aNotification];
         }];
    }
}

- (void)applicationSyncManagerWillRemoveAllRemoteSyncData:(NSNotification *)aNotification
{}

#pragma mark - OPERATION COMMUNICATIONS

- (void)operationCompletedSuccessfully:(TICDSOperation *)anOperation
{
    if ([anOperation isKindOfClass:[TICDSDocumentRegistrationOperation class]]) {
        [self documentRegistrationOperationCompleted:(id)anOperation];
    } else if ([anOperation isKindOfClass:[TICDSWholeStoreUploadOperation class]]) {
        [self wholeStoreUploadOperationCompleted:(id)anOperation];
    } else if ([anOperation isKindOfClass:[TICDSPreSynchronizationOperation class]]) {
        [self preSynchronizationOperationCompleted:(id)anOperation];
    } else if ([anOperation isKindOfClass:[TICDSSynchronizationOperation class]]) {
        [self synchronizationOperationCompleted:(id)anOperation];
    } else if ([anOperation isKindOfClass:[TICDSPostSynchronizationOperation class]]) {
        [self postSynchronizationOperationCompleted:(id)anOperation];
    } else if ([anOperation isKindOfClass:[TICDSVacuumOperation class]]) {
        [self vacuumOperationCompleted:(id)anOperation];
    } else if ([anOperation isKindOfClass:[TICDSWholeStoreDownloadOperation class]]) {
        [self wholeStoreDownloadOperationCompleted:(id)anOperation];
    } else if ([anOperation isKindOfClass:[TICDSListOfDocumentRegisteredClientsOperation class]]) {
        [self registeredClientsOperationCompleted:(id)anOperation];
    } else if ([anOperation isKindOfClass:[TICDSDocumentClientDeletionOperation class]]) {
        [self documentClientDeletionOperationCompleted:(id)anOperation];
    }
}

- (void)operationWasCancelled:(TICDSOperation *)anOperation
{
    if ([anOperation isKindOfClass:[TICDSDocumentRegistrationOperation class]]) {
        [self documentRegistrationOperationWasCancelled:(id)anOperation];
    } else if ([anOperation isKindOfClass:[TICDSWholeStoreUploadOperation class]]) {
        [self wholeStoreUploadOperationWasCancelled:(id)anOperation];
    } else if ([anOperation isKindOfClass:[TICDSPreSynchronizationOperation class]]) {
        [self preSynchronizationOperationWasCancelled:(id)anOperation];
    } else if ([anOperation isKindOfClass:[TICDSSynchronizationOperation class]]) {
        [self synchronizationOperationWasCancelled:(id)anOperation];
    } else if ([anOperation isKindOfClass:[TICDSPostSynchronizationOperation class]]) {
        [self postSynchronizationOperationWasCancelled:(id)anOperation];
    } else if ([anOperation isKindOfClass:[TICDSVacuumOperation class]]) {
        [self vacuumOperationWasCancelled:(id)anOperation];
    } else if ([anOperation isKindOfClass:[TICDSWholeStoreDownloadOperation class]]) {
        [self wholeStoreDownloadOperationWasCancelled:(id)anOperation];
    } else if ([anOperation isKindOfClass:[TICDSListOfDocumentRegisteredClientsOperation class]]) {
        [self registeredClientsOperationWasCancelled:(id)anOperation];
    } else if ([anOperation isKindOfClass:[TICDSDocumentClientDeletionOperation class]]) {
        [self documentClientDeletionOperationWasCancelled:(id)anOperation];
    }
}

- (void)operationFailedToComplete:(TICDSOperation *)anOperation
{
    if ([anOperation isKindOfClass:[TICDSDocumentRegistrationOperation class]]) {
        [self documentRegistrationOperation:(id)anOperation failedToCompleteWithError:[anOperation error]];
    } else if ([anOperation isKindOfClass:[TICDSWholeStoreUploadOperation class]]) {
        [self wholeStoreUploadOperation:(id)anOperation failedToCompleteWithError:[anOperation error]];
    } else if ([anOperation isKindOfClass:[TICDSPreSynchronizationOperation class]]) {
        [self preSynchronizationOperation:(id)anOperation failedToCompleteWithError:[anOperation error]];
    } else if ([anOperation isKindOfClass:[TICDSSynchronizationOperation class]]) {
        [self synchronizationOperation:(id)anOperation failedToCompleteWithError:[anOperation error]];
    } else if ([anOperation isKindOfClass:[TICDSPostSynchronizationOperation class]]) {
        [self postSynchronizationOperation:(id)anOperation failedToCompleteWithError:[anOperation error]];
    } else if ([anOperation isKindOfClass:[TICDSVacuumOperation class]]) {
        [self vacuumOperation:(id)anOperation failedToCompleteWithError:[anOperation error]];
    } else if ([anOperation isKindOfClass:[TICDSWholeStoreDownloadOperation class]]) {
        [self wholeStoreDownloadOperation:(id)anOperation failedToCompleteWithError:[anOperation error]];
    } else if ([anOperation isKindOfClass:[TICDSListOfDocumentRegisteredClientsOperation class]]) {
        [self registeredClientsOperation:(id)anOperation failedToCompleteWithError:[anOperation error]];
    } else if ([anOperation isKindOfClass:[TICDSDocumentClientDeletionOperation class]]) {
        [self documentClientDeletionOperation:(id)anOperation failedToCompleteWithError:[anOperation error]];
    }
}

#pragma mark - TICoreDataFactory Delegate

- (void)coreDataFactory:(TICoreDataFactory *)aFactory encounteredError:(NSError *)anError
{
    TICDSLog(TICDSLogVerbosityErrorsOnly, @"TICoreDataFactory error: %@", anError);
}

#pragma mark - Initialization and Deallocation

- (id)init
{
    self = [super init];
    if (self == nil) {
        return nil;
    }

    // Create the dictionary for the sync changes managed object contexts
    _syncChangesMOCs = [[NSMutableDictionary alloc] initWithCapacity:5];

    // Create Registration Queue (suspended, but unsuspended if App Sync Man is registered when registerWithDelegate:... is called)
    _registrationQueue = [[NSOperationQueue alloc] init];
    [_registrationQueue setSuspended:YES];

    // Create Other Queues (suspended until registration completes)
    _synchronizationQueue = [[NSOperationQueue alloc] init];
    [_synchronizationQueue setSuspended:YES];
    [_synchronizationQueue setMaxConcurrentOperationCount:1];

    _otherTasksQueue = [[NSOperationQueue alloc] init];
    [_otherTasksQueue setSuspended:YES];
    [_otherTasksQueue setMaxConcurrentOperationCount:1];

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    _applicationSyncManager = nil;
    _documentIdentifier = nil;
    _clientIdentifier = nil;
    _documentUserInfo = nil;
    _fileManager = nil;
    _helperFileDirectoryLocation = nil;
    _primaryDocumentMOC = nil;
    _syncChangesMOCs = nil;
    _coreDataFactory = nil;
    _registrationQueue = nil;
    _synchronizationQueue = nil;
    _otherTasksQueue = nil;
    _integrityKey = nil;
}

#pragma mark - Lazy Accessors

- (NSFileManager *)fileManager
{
    if (_fileManager) {
        return _fileManager;
    }

    _fileManager = [[NSFileManager alloc] init];

    return _fileManager;
}

- (TICoreDataFactory *)coreDataFactory
{
    if (_coreDataFactory) {
        return _coreDataFactory;
    }

    TICDSLog(TICDSLogVerbosityEveryStep, @"Creating Core Data Factory (TICoreDataFactory)");
    _coreDataFactory = [[TICoreDataFactory alloc] initWithMomdName:TICDSSyncChangeDataModelName];
    [_coreDataFactory setDelegate:self];
    [_coreDataFactory setPersistentStoreType:TICDSSyncChangesCoreDataPersistentStoreType];
    [_coreDataFactory setPersistentStoreDataPath:self.unsynchronizedSyncChangesStorePath];

    return _coreDataFactory;
}

#pragma mark - Paths

- (NSString *)relativePathToClientDevicesDirectory
{
    return TICDSClientDevicesDirectoryName;
}

- (NSString *)relativePathToInformationDirectory
{
    return TICDSInformationDirectoryName;
}

- (NSString *)relativePathToInformationDeletedDocumentsDirectory
{
    return [self.relativePathToInformationDirectory stringByAppendingPathComponent:TICDSDeletedDocumentsDirectoryName];
}

- (NSString *)relativePathToDeletedDocumentsThisDocumentIdentifierPlistFile
{
    return [self.relativePathToInformationDeletedDocumentsDirectory stringByAppendingPathComponent:[self.documentIdentifier stringByAppendingPathExtension:TICDSDocumentInfoPlistExtension]];
}

- (NSString *)relativePathToDocumentsDirectory
{
    return TICDSDocumentsDirectoryName;
}

- (NSString *)relativePathToThisDocumentDirectory
{
    return [self.relativePathToDocumentsDirectory stringByAppendingPathComponent:self.documentIdentifier];
}

- (NSString *)relativePathToThisDocumentDeletedClientsDirectory
{
    return [self.relativePathToThisDocumentDirectory stringByAppendingPathComponent:TICDSDeletedClientsDirectoryName];
}

- (NSString *)relativePathToThisDocumentSyncChangesDirectory
{
    return [[self relativePathToThisDocumentDirectory] stringByAppendingPathComponent:TICDSSyncChangesDirectoryName];
}

- (NSString *)relativePathToThisDocumentSyncChangesThisClientDirectory
{
    return [self.relativePathToThisDocumentSyncChangesDirectory stringByAppendingPathComponent:self.clientIdentifier];
}

- (NSString *)relativePathToThisDocumentSyncCommandsDirectory
{
    return [[self relativePathToThisDocumentDirectory] stringByAppendingPathComponent:TICDSSyncCommandsDirectoryName];
}

- (NSString *)relativePathToThisDocumentSyncCommandsThisClientDirectory
{
    return [self.relativePathToThisDocumentSyncCommandsDirectory stringByAppendingPathComponent:self.clientIdentifier];
}

- (NSString *)relativePathToThisDocumentTemporaryFilesDirectory
{
    return [[self relativePathToThisDocumentDirectory] stringByAppendingPathComponent:TICDSTemporaryFilesDirectoryName];
}

- (NSString *)relativePathToThisDocumentTemporaryWholeStoreDirectory
{
    return [self.relativePathToThisDocumentTemporaryFilesDirectory stringByAppendingPathComponent:TICDSWholeStoreDirectoryName];
}

- (NSString *)relativePathToThisDocumentTemporaryWholeStoreThisClientDirectory
{
    return [self.relativePathToThisDocumentTemporaryWholeStoreDirectory stringByAppendingPathComponent:self.clientIdentifier];
}

- (NSString *)relativePathToThisDocumentTemporaryWholeStoreThisClientDirectoryWholeStoreFile
{
    return [self.relativePathToThisDocumentTemporaryWholeStoreThisClientDirectory stringByAppendingPathComponent:TICDSWholeStoreFilename];
}

- (NSString *)relativePathToThisDocumentTemporaryWholeStoreThisClientDirectoryAppliedSyncChangeSetsFile
{
    return [self.relativePathToThisDocumentTemporaryWholeStoreThisClientDirectory stringByAppendingPathComponent:TICDSAppliedSyncChangeSetsFilename];
}

- (NSString *)relativePathToThisDocumentWholeStoreDirectory
{
    return [[self relativePathToThisDocumentDirectory] stringByAppendingPathComponent:TICDSWholeStoreDirectoryName];
}

- (NSString *)relativePathToThisDocumentWholeStoreThisClientDirectory
{
    return [self.relativePathToThisDocumentWholeStoreDirectory stringByAppendingPathComponent:self.clientIdentifier];
}

- (NSString *)relativePathToThisDocumentWholeStoreThisClientDirectoryWholeStoreFile
{
    return [self.relativePathToThisDocumentWholeStoreThisClientDirectory stringByAppendingPathComponent:TICDSWholeStoreFilename];
}

- (NSString *)relativePathToThisDocumentWholeStoreThisClientDirectoryAppliedSyncChangeSetsFile
{
    return [self.relativePathToThisDocumentWholeStoreThisClientDirectory stringByAppendingPathComponent:TICDSAppliedSyncChangeSetsFilename];
}

- (NSString *)relativePathToThisDocumentRecentSyncsDirectory
{
    return [[self relativePathToThisDocumentDirectory] stringByAppendingPathComponent:TICDSRecentSyncsDirectoryName];
}

- (NSString *)relativePathToThisDocumentRecentSyncsDirectoryThisClientFile
{
    return [[self.relativePathToThisDocumentRecentSyncsDirectory stringByAppendingPathComponent:self.clientIdentifier] stringByAppendingPathExtension:TICDSRecentSyncFileExtension];
}

- (NSString *)localAppliedSyncChangesFilePath
{
    return [[self.helperFileDirectoryLocation path] stringByAppendingPathComponent:TICDSAppliedSyncChangeSetsFilename];
}

- (NSString *)syncChangesBeingSynchronizedStorePath
{
    return [[self.helperFileDirectoryLocation path] stringByAppendingPathComponent:TICDSSyncChangesBeingSynchronizedStoreName];
}

- (NSString *)unsynchronizedSyncChangesStorePath
{
    return [[self.helperFileDirectoryLocation path] stringByAppendingPathComponent:TICDSUnsynchronizedSyncChangesStoreName];
}

#pragma mark - Properties

@synthesize delegate = _delegate;
@synthesize shouldUseEncryption = _shouldUseEncryption;
@synthesize mustUploadStoreAfterRegistration = _mustUploadStoreAfterRegistration;
@synthesize state = _state;
@synthesize applicationSyncManager = _applicationSyncManager;
@synthesize documentIdentifier = _documentIdentifier;
@synthesize documentDescription = _documentDescription;
@synthesize clientIdentifier = _clientIdentifier;
@synthesize documentUserInfo = _documentUserInfo;
@synthesize fileManager = _fileManager;
@synthesize helperFileDirectoryLocation = _helperFileDirectoryLocation;
@synthesize primaryDocumentMOC = _primaryDocumentMOC;
@synthesize coreDataFactory = _coreDataFactory;
@synthesize syncChangesMOCs = _syncChangesMOCs;
@synthesize registrationQueue = _registrationQueue;
@synthesize synchronizationQueue = _synchronizationQueue;
@synthesize otherTasksQueue = _otherTasksQueue;
@synthesize integrityKey = _integrityKey;

@end
