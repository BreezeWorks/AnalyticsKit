//  LocalyticsSession.m
//  Copyright (C) 2013 Char Software Inc., DBA Localytics
//
//  This code is provided under the Localytics Modified BSD License.
//  A copy of this license has been distributed in a file called LICENSE
//  with this source code.
//
// Please visit www.localytics.com for more information.

#import "LocalyticsSession.h"
#import "LocalyticsSession+Private.h"
#import "LocalyticsConstants.h"
#import "LocalyticsUploader.h"
#import "LocalyticsDatabase.h"
#import "LocalyticsDatapointHelper.h"
#import "LocalyticsUtil.h"

#include <CommonCrypto/CommonDigest.h>


// The singleton session object.
static LocalyticsSession *_sharedLocalyticsSession = nil;

@implementation LocalyticsSession

@synthesize queue                       = _queue;
@synthesize criticalGroup               = _criticalGroup;
@synthesize sessionUUID                 = _sessionUUID;
@synthesize applicationKey              = _applicationKey;
@synthesize lastSessionStartTimestamp   = _lastSessionStartTimestamp;
@synthesize sessionResumeTime           = _sessionResumeTime;
@synthesize sessionCloseTime            = _sessionCloseTime;
@synthesize isSessionOpen               = _isSessionOpen;
@synthesize hasInitialized              = _hasInitialized;
@synthesize sessionTimeoutInterval		= _sessionTimeoutInterval;
@synthesize unstagedFlowEvents          = _unstagedFlowEvents;
@synthesize stagedFlowEvents            = _stagedFlowEvents;
@synthesize screens                     = _screens;
@synthesize sessionActiveDuration       = _sessionActiveDuration;
@synthesize sessionHasBeenOpen          = _sessionHasBeenOpen;
@synthesize sessionNumber               = _sessionNumber;
@synthesize enableHTTPS                 = _enableHTTPS;
@synthesize localyticsDelegate          = _localyticsDelegate;
@synthesize needsSessionStartActions    = _needsSessionStartActions;
@synthesize needsFirstRunActions        = _needsFirstRunActions;
@synthesize needsUpgradeActions         = _needsUpgradeActions;

// Stores the last location passed in to the app.
CLLocationCoordinate2D lastDeviceLocation = {0,0};

#pragma mark Singleton
+ (LocalyticsSession *)sharedLocalyticsSession
{
	return [LocalyticsSession shared];
}

+ (LocalyticsSession *)shared {
	@synchronized(self) {
		if (_sharedLocalyticsSession == nil) {
            _sharedLocalyticsSession = [[self alloc] init];
		}
	}
	return _sharedLocalyticsSession;
}

- (LocalyticsSession *)init
{
	if((self = [super init])) {
		_isSessionOpen  = NO;
		_hasInitialized = NO;
		_sessionTimeoutInterval = DEFAULT_BACKGROUND_SESSION_TIMEOUT;
		_sessionHasBeenOpen = NO;
		_queue = dispatch_queue_create("com.Localytics.operations", DISPATCH_QUEUE_SERIAL);
		_criticalGroup = dispatch_group_create();
		_enableHTTPS = NO;
        _needsSessionStartActions = NO;
        _needsFirstRunActions = NO;
        _needsUpgradeActions = NO;
		[_sharedLocalyticsSession db];
		
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
		
		LocalyticsLog("Localytics core module initialized");
	}
	
	return self;
}

#pragma mark Public Methods

- (void)LocalyticsSession:(NSString *)appKey
{
	// Take ownership of the appKey, which was directly passed in from the app
	// to ensure that it doesn't get released.
	[appKey retain];
	
	if([LocalyticsSession appKeyIsValid:appKey] == NO)
	{
		[[NSException exceptionWithName:@"Invalid Localytics App Key"
								 reason:@"The application exception was intentional due to an invalid or incomplete Localytics Application Key. Please verify the Localytics Application Key in the Administration panel and for further details please review the iOS integration guidelines at: http://www.localytics.com/docs/iphone-integration/"
							   userInfo:nil] raise];
		[appKey release];
		return;
	}
	
	dispatch_async(_queue, ^{
		@try {
			if ([[LocalyticsSession shared] db]) {
				// Check if the app key has changed.
				NSString *lastAppKey = [[[LocalyticsSession shared] db] appKey];
				if (![lastAppKey isEqualToString:appKey]) {
					if (lastAppKey) {
						// Clear previous events and dimensions to guarantee that new data isn't associated with the old app key.
						[[[LocalyticsSession shared] db] resetAnalyticsData];
						
						// Vacuum to improve the odds of opening a new session following bulk delete.
						[[[LocalyticsSession shared] db] vacuumIfRequired];
					}
					// Record the key for future checks.
					[[[LocalyticsSession shared] db] updateAppKey:appKey];
				}
                
                // Check for first run
                self.needsFirstRunActions = [[[LocalyticsSession shared] db] firstRun];
                
                // Check for app upgrade
                NSString *currentAppVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"];
                NSString *storedAppVersion = [[[LocalyticsSession shared] db] appVersion];
                if (storedAppVersion && ![currentAppVersion isEqualToString:storedAppVersion])
                    self.needsUpgradeActions = YES;
                if (storedAppVersion == nil || ![currentAppVersion isEqualToString:storedAppVersion])
                    [[[LocalyticsSession shared] db] updateAppVersion:currentAppVersion];
				
				self.applicationKey = appKey;
				self.hasInitialized = YES;
				
                [self updateFirstAdidIfNeeded];
                
				LocalyticsLog("Object Initialized.  Application's key is: %@", self.applicationKey);
				
				if (!NSClassFromString(@"ASIdentifierManager") && ([[[UIDevice currentDevice] systemVersion] floatValue] >= 6.0f))
				{
					NSLog(@"\n\n" \
						  "**********************************************\n" \
						  "- LOCALYTICS WARNING -\n" \
						  "AdSupport.framework not detected.\n\n" \
						  "This is required to properly track user retention using Apple's 'advertisingIdentifier'.\n" \
						  "Please link against this framework and set the reference to 'Optional' to ensure backwards\n" \
						  "compatibility with pre-iOS 6 devices. Please reference the iOS integration guide for further information\n" \
						  "http://www.localytics.com/docs/iphone-integration/#instruction\n" \
						  "**********************************************\n\n");
				}
			}
		}
		@catch (NSException * e) {}
		
		[appKey release];
	});
}

- (BOOL)loggingEnabled
{
    return [LocalyticsUtil loggingEnabled];
}

- (void)setLoggingEnabled:(BOOL)loggingEnabled
{
    [LocalyticsUtil setLoggingEnabled:loggingEnabled];
}

- (BOOL)advertisingIdentifierEnabled
{
	return [LocalyticsUtil advertisingIdentifierEnabled];
}

- (void)setAdvertisingIdentifierEnabled:(BOOL)advertisingIdentifierEnabled
{
	[LocalyticsUtil setAdvertisingIdentifierEnabled:advertisingIdentifierEnabled];
}

- (void)startSession:(NSString *)appKey
{
	// Create a session
	[self LocalyticsSession:appKey];
	[self open];
	[self upload];
}

// Public interface to ll_open.
- (void)open
{
	dispatch_async(_queue, ^{
		[self ll_open];
	});
}

- (void)resume
{
	dispatch_async(_queue, ^{
		@try {
			// Do nothing if session is already open
			if(self.isSessionOpen == YES)
			{
				[self callbackWithDidResume:NO];
				return;
			}
			
			// Do nothing if the user is opted out
			if([self ll_isOptedIn] == false) {
				LocalyticsLog("Can't resume session because user is opted out.");
				[self callbackWithDidResume:NO];
				return;
			}
			
			// Conditions for resuming previous session
			if(self.sessionHasBeenOpen &&
			   (!self.sessionCloseTime ||
				[self.sessionCloseTime timeIntervalSinceNow]*-1 <= self.sessionTimeoutInterval)) {
				   // Note that we allow the session to be resumed even if the database size exceeds the
				   // maximum. This is because we don't want to create incomplete sessions. If the DB was large
				   // enough that the previous session could not be opened, there will be nothing to resume. But
				   // if this session caused it to go over it is better to let it complete and stop the next one
				   // from being created.
				   LocalyticsLog("Resume called - Resuming previous session.");
				   [self reopenPreviousSession];
				   [self callbackWithDidResume:YES];
			   }
			else {
				// Otherwise, open new session and upload
				LocalyticsLog("Resume called - Opening a new session.");
				[self ll_open];
				[self callbackWithDidResume:NO];
			}
			
			// Clear stale properties
			self.sessionCloseTime = nil;
			
		}
		@catch (NSException * e) {}
	});
}

- (void)callbackWithDidResume:(BOOL)didResumeExistingSession
{
	// Provide optional localyticsResumedSession callback to Localytics delegate
	if(self.localyticsDelegate &&
	   [self.localyticsDelegate respondsToSelector:@selector(localyticsResumedSession:)])
	{
		// Call them back on the main thread, not the Localytics private queue
		dispatch_async(dispatch_get_main_queue(), ^{
			[self.localyticsDelegate localyticsResumedSession:didResumeExistingSession];
		});
	}
}

- (void)close
{
	dispatch_group_async(_criticalGroup, _queue, ^{
		@try {
			
			// Do nothing if the session is not open
			if (self.isSessionOpen == NO) {
				LocalyticsLog("Unable to close session");
				return;
			}
			
			// Save time of close
			self.sessionCloseTime = [NSDate date];
			
			// Update active session duration.
			self.sessionActiveDuration += [self.sessionCloseTime timeIntervalSinceDate:self.sessionResumeTime];
			
			int sessionLength = (int)[[NSDate date] timeIntervalSince1970] - self.lastSessionStartTimestamp;
			
			
			// Create the JSON representing the close blob
			NSMutableString *closeEventString = [NSMutableString string];
			[closeEventString appendString:@"{"];
			[closeEventString appendString:[self formatAttributeWithName:PARAM_DATA_TYPE         value:@"c"                      first:YES]];
			[closeEventString appendString:[self formatAttributeWithName:PARAM_SESSION_UUID      value:self.sessionUUID]];
			[closeEventString appendString:[self formatAttributeWithName:PARAM_UUID              value:[self randomUUID] ]];
			[closeEventString appendFormat:@",\"%@\":%ld", PARAM_SESSION_START, (long)self.lastSessionStartTimestamp];
			[closeEventString appendFormat:@",\"%@\":%ld", PARAM_SESSION_ACTIVE, (long)self.sessionActiveDuration];
			[closeEventString appendFormat:@",\"%@\":%ld", PARAM_CLIENT_TIME, (long)[self currentTimestamp]];
			
			// Avoid recording session lengths of users with unreasonable client times (usually caused by developers testing clock change attacks)
			if(sessionLength > 0 && sessionLength < 400000) {
				[closeEventString appendFormat:@",\"%@\":%d", PARAM_SESSION_TOTAL, sessionLength];
			}
			
			// Open second level - screen flow
			[closeEventString appendFormat:@",\"%@\":[", PARAM_SESSION_SCREENFLOW];
			[closeEventString appendString:self.screens];
			
			// Close second level - screen flow
			[closeEventString appendString:@"]"];
			
			// Append the custom dimensions
			[closeEventString appendString:[self customDimensions]];
			
			// Append the location
			[closeEventString appendString:[self locationDimensions]];
			
			// Close first level - close blob
			[closeEventString appendString:@"}\n"];
			
			BOOL success = [[self db] queueCloseEventWithBlobString:[[closeEventString copy] autorelease]];
			
			self.isSessionOpen = NO;  // Session is no longer open.
			
			if (success) {
				LocalyticsLog("Session succesfully closed.");
			}
			else {
				LocalyticsLog("Failed to record session close.");
			}
		}
		@catch (NSException * e) {}
	});
}

- (void)setOptIn:(BOOL)optedIn
{
	dispatch_async(_queue, ^{
		@try {
			LocalyticsDatabase *db = [self db];
			NSString *t = @"set_opt";
			BOOL success = [db beginTransaction:t];
			
			// Write out opt event.
			if (success) {
				success =  [self createOptEvent:optedIn];
			}
			
			// Update database with the option (stored internally as an opt-out).
			if (success) {
				[db setOptedOut:optedIn == NO];
			}
			
			if (success && optedIn == NO) {
				// Disable all further Localytics calls for this and future sessions
				// This should not be flipped when the session is opted back in because that
				// would create an incomplete session.
				self.isSessionOpen = NO;
			}
			
			if (success) {
				[db releaseTransaction:t];
				LocalyticsLog("Application opted %@", optedIn ? @"in" : @"out");
			} else {
				[db rollbackTransaction:t];
				LocalyticsLog("Failed to update opt state.");
			}
		}
		@catch (NSException * e) {}
	});
}

// A convenience function for users who don't wish to add attributes.
- (void)tagEvent:(NSString *)event
{
	[self tagEvent:event attributes:nil reportAttributes:nil];
}

// Most users should use this tagEvent call.
- (void)tagEvent:(NSString *)event attributes:(NSDictionary *)attributes
{
	[self tagEvent:event attributes:attributes reportAttributes:nil];
}

- (void)tagEvent:(NSString *)event attributes:(NSDictionary *)attributes customerValueIncrease:(NSNumber *)value
{
	[self tagEvent:event attributes:attributes reportAttributes:nil customerValueIncrease:value];
}

- (void)tagEvent:(NSString *)event attributes:(NSDictionary *)attributes reportAttributes:(NSDictionary *)reportAttributes
{
	[self tagEvent:event attributes:attributes reportAttributes:reportAttributes customerValueIncrease:nil];
}

- (void)tagEvent:(NSString *)event attributes:(NSDictionary *)attributes reportAttributes:(NSDictionary *)reportAttributes customerValueIncrease:(NSNumber *)value
{
	dispatch_async(_queue, ^{
		@try {
			// Do nothing if the session is not open.
			if (self.isSessionOpen == NO)
			{
				LocalyticsLog("Cannot tag an event because the session is not open.");
				return;
			}
			
			if(event == (id)[NSNull null] || event.length == 0)
			{
				LocalyticsLog("Event tagged without a name. Skipping.");
				return;
			}
			
			
			// Create the JSON for the event
			NSMutableString *eventString = [[[NSMutableString alloc] init] autorelease];
			[eventString appendString:@"{"];
			
			[eventString appendString:
			 [self formatAttributeWithName:PARAM_DATA_TYPE
									 value:@"e" first:YES] ];
			[eventString appendString:
			 [self formatAttributeWithName:PARAM_UUID
									 value:[self randomUUID] ]];
			[eventString appendString:
			 [self formatAttributeWithName:PARAM_APP_KEY
									 value:self.applicationKey ]];
			[eventString appendString:
			 [self formatAttributeWithName:PARAM_SESSION_UUID
									 value:self.sessionUUID ]];
			[eventString appendString:
			 [self formatAttributeWithName:PARAM_EVENT_NAME
									 value:[self escapeString:event] ]];
			
			if(value)
			{
				[eventString appendString:
				 [self formatAttributeWithName:PARAM_VALUE_NAME
										 value:[value stringValue] ]];
			}
			
			[eventString appendFormat:@",\"%@\":%ld", PARAM_CLIENT_TIME, (long)[self currentTimestamp]];
			
			
			// Append the custom dimensions
			[eventString appendString:[self customDimensions]];
			
			
			// Append the location
			[eventString appendString:[self locationDimensions]];
			
			
			// If there are any attributes for this event, add them as a hash
			int attrIndex = 0;
			if(attributes != nil)
			{
				// Open second level - attributes
				[eventString appendString:[NSString stringWithFormat:@",\"%@\":{", PARAM_ATTRIBUTES]];
				for (id key in [attributes allKeys])
				{
					// Have to escape paramName and paramValue because they user-defined.
					[eventString appendString:
					 [self formatAttributeWithName:[self escapeString:[key description]]
											 value:[self escapeString:[[attributes valueForKey:key] description]]
											 first:(attrIndex == 0)]];
					attrIndex++;
				}
				
				// Close second level - attributes
				[eventString appendString:@"}"];
			}
			
			
			// If there are any report attributes for this event, add them as above
			attrIndex = 0;
			if(reportAttributes != nil)
			{
				[eventString appendString:[NSString stringWithFormat:@",\"%@\":{", PARAM_REPORT_ATTRIBUTES]];
				for(id key in [reportAttributes allKeys]) {
					[eventString appendString:
					 [self formatAttributeWithName:[self escapeString:[key description]]
											 value:[self escapeString:[[reportAttributes valueForKey:key] description]]
											 first:(attrIndex == 0)]];
					attrIndex++;
				}
				[eventString appendString:@"}"];
			}
			
			
			// Close first level - Event information
			[eventString appendString:@"}\n"];
			
			BOOL success = [[self db] addEventWithBlobString:[[eventString copy] autorelease]];
			if (success) {
				// User-originated events should be tracked as application flow.
				[self addFlowEventWithName:event type:@"e"]; // "e" for Event.
				
				LocalyticsLog("Tagged event: %@", event);
			}
			else {
				LocalyticsLog("Failed to tag event.");
			}
		}
		@catch (NSException * e) {}
	});
}

- (void)tagScreen:(NSString *)screen
{
	dispatch_async(_queue, ^{
		// Do nothing if the session is not open.
		if (self.isSessionOpen == NO)
		{
			LocalyticsLog("Cannot tag a screen because the session is not open.");
			return;
		}
		
		// Tag screen with description to enforce string type and avoid retaining objects passed by clients in lieu of a
		// screen name.
		NSString *screenName = [screen description];
		[self addFlowEventWithName:screenName type:@"s"]; // "s" for Screen.
		
		// Maintain a parallel list of only screen names. This is submitted in the session close event.
		// This may be removed in a future version of the client library.
		[self addScreenWithName:screenName];
		
		LocalyticsLog("Tagged screen: %@", screenName);;
	});
}

- (void)setLocation:(CLLocationCoordinate2D)deviceLocation
{
	lastDeviceLocation = deviceLocation;
	LocalyticsLog("Setting Location");
}

- (void)setPushToken:(NSData *)pushToken
{
    dispatch_async(_queue, ^{
		@try {
            NSString *tokenString = @"";
            if (pushToken && pushToken.length > 0)
            {
                tokenString = [[pushToken description] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"<>"]];
                tokenString = [tokenString stringByReplacingOccurrencesOfString:@" " withString:@""];
            }
            
            BOOL isDevBuild = [LocalyticsDatapointHelper isDevBuild];
            
			LocalyticsDatabase *db = [self db];
			NSString *t = @"set_push_token";
			BOOL success = [db beginTransaction:t];
                        
			if (success)
            {
                if (isDevBuild)
                {
                    success = [[self db] updateDevPushToken:tokenString];
                    
                    // Clear the prod token if it has been set
                    if ([[self db] isPushTokenNull] == NO)
                    {
                        success = [[self db] updatePushToken:@""];
                    }
                }
                else
                {
                    success = [[self db] updatePushToken:tokenString];
                    
                    // Clear the dev token if it has been set
                    if ([[self db] isDevPushTokenNull] == NO)
                    {
                        success = [[self db] updateDevPushToken:@""];
                    }                    
                }                
			}
			
			NSString *buildType = isDevBuild ? @"Development" : @"Production";
            
			if (success)
            {
				[db releaseTransaction:t];
				LocalyticsLog("%@ push token updated to: %@", buildType, tokenString);
			}
            else
            {
				[db rollbackTransaction:t];
				LocalyticsLog("Failed to update %@ push token.", buildType);
			}
		}
		@catch (NSException * e) {}
	});
}

- (void)setCustomDimension:(int)dimension value:(NSString *)value
{
	if(dimension < 0 || dimension > 9) {
		LocalyticsLog("Only valid dimensions are 0 - 9");
		return;
	}
	
	dispatch_async(_queue, ^{
		if(![[self db] setCustomDimension:dimension value:value]) {
			LocalyticsLog("Unable to set custom dimensions.");
		}
	});
}

- (void)setValueForIdentifier:(NSString *)identifierName value:(NSString *)value
{
	if(identifierName.length == 0) {
		LocalyticsLog("Cannot set user identifier. Empty key value");
		return;
	}
	
	// If the identifier value is nil, then delete the entry from the db
	if(value.length == 0) {
		dispatch_async(_queue, ^{
			@try {
				if(![[self db] deleteIdentifer:identifierName]) {
					LocalyticsLog("Failed to delete identifier with key %@", identifierName);
				}
			}
			@catch (NSException *e) {}
		});
	}
	
	// Otherwise update or insert the key/value pair into the db
	else {
		dispatch_async(_queue, ^{
			@try {
				if(![[self db] setValueForIdentifier:identifierName value:value]) {
					LocalyticsLog("Unable to set user identifier %@ with value %@", identifierName, value);
				}
			}
			@catch (NSException *e) {}
		});
	}
	
}

- (void)setCustomerName:(NSString *)customerName
{
	[self setValueForIdentifier:@"customer_name" value:customerName];
}

- (void)setCustomerId:(NSString *)customerId
{
	[self setValueForIdentifier:@"customer_id" value:customerId];
}

- (void)setCustomerEmail:(NSString *)email
{
	[self setValueForIdentifier:@"email" value:email];
}


- (void)upload
{	
	dispatch_group_async(_criticalGroup, _queue, ^{
		@try {
			if ([[self uploader] isUploading]) {
				LocalyticsLog("An upload is already in progress. Aborting.");
				return;
			}
			
			NSString *t = @"stage_upload";
			LocalyticsDatabase *db = [self db];
			BOOL success = [db beginTransaction:t];
			
			// - The event list for the current session is not modified
			// New flow events are only transitioned to the "old" list if the upload is staged successfully. The queue
			// ensures that the list of events are not modified while a call to upload is in progress.
			if (success) {
				// Write flow blob to database. This is for a session in progress and should not be removed upon resume.
				success = [self saveApplicationFlowAndRemoveOnResume:NO];
			}
			
			if (success && [self uploadIsNeeded])
			{
				// Increment upload sequence number.
				int sequenceNumber = 0;
				success = [db incrementLastUploadNumber:&sequenceNumber];
				
				// Write out header to database.
				sqlite3_int64 headerRowId = 0;
				if (success) {
					NSString *headerBlob = [self blobHeaderStringWithSequenceNumber:sequenceNumber];
					success = [db addHeaderWithSequenceNumber:sequenceNumber blobString:headerBlob rowId:&headerRowId];
				}
				
				// Associate unstaged events.
				if (success) {
					success = [db stageEventsForUpload:headerRowId];
				}
			}
			
			if (success) {
				// Complete transaction
				[db releaseTransaction:t];
				
				// Move new flow events to the old flow event array.
				if (self.unstagedFlowEvents.length) {
					if (self.stagedFlowEvents.length) {
						[self.stagedFlowEvents appendFormat:@",%@", self.unstagedFlowEvents];
					} else {
						self.stagedFlowEvents = [[self.unstagedFlowEvents mutableCopy] autorelease];
					}
					self.unstagedFlowEvents = [NSMutableString string];
				}
				            
				// Begin upload.
				[[self uploader] uploaderWithApplicationKey:self.applicationKey
												   useHTTPS:[self enableHTTPS]
												  installId:[self installationId]
											 libraryVersion:[self libraryVersion]
                                           completionTarget:self
                                         completionCallback:@selector(uploadCallback:)
                                        prepareUploadTarget:self.localyticsDelegate
                                      prepareUploadCallback:@selector(localyticsPrepareUploadBody:)];
			}
			else {
				[db rollbackTransaction:t];
				LocalyticsLog("Failed to start upload.");
			}
		}
		@catch (NSException * e) { }
	});
}

- (BOOL)uploadIsNeeded
{
	return [[self db] unstagedEventCount] > 0;
}

- (void)onStartSession {}

- (void)onFirstRun {}

- (void)onUpgrade {}

- (void)updateFirstAdidIfNeeded
{
    if ([[self db] isFirstAdidNull])
    {
        NSString *advertisingIdentifier = [LocalyticsDatapointHelper advertisingIdentifier];
        
        if (advertisingIdentifier && ![advertisingIdentifier isEqualToString:@""])
        {
            [[self db] updateFirstAdid:advertisingIdentifier];
        }
    }
}

#pragma mark Private Methods

- (NSString*)libraryVersion
{
	return [NSString stringWithFormat:@"%@_%@",CLIENT_VERSION_PREFIX, CLIENT_VERSION];
}

- (void)uploadCallback:(NSDictionary*)info
{
#pragma unused(info)
    if (self.needsFirstRunActions)
    {
        [self onFirstRun];
        self.needsFirstRunActions = NO;
    }

    if (self.needsUpgradeActions)
    {
        [self onUpgrade];
        self.needsUpgradeActions = NO;
    }

    if (self.needsSessionStartActions)
    {
        [self onStartSession];
        self.needsSessionStartActions = NO;
    }
}

- (void)dequeueCloseEventBlobString
{
	LocalyticsDatabase *db = [self db];
	NSString *closeEventString = [db dequeueCloseEventBlobString];
	if (closeEventString) {
		BOOL success = [db addCloseEventWithBlobString:closeEventString];
		if (!success) {
			// Re-queue the close event.
			[db queueCloseEventWithBlobString:closeEventString];
		}
	}
}

- (void)ll_open
{
	@try {
		// There are a number of conditions in which nothing should be done:
		if (self.hasInitialized == NO ||  // the session object has not yet initialized
			self.isSessionOpen == YES)  // session has already been opened
		{
			LocalyticsLog("Unable to open session.");
			return;
		}
		
		if([self ll_isOptedIn] == false) {
			LocalyticsLog("Can't open session because user is opted out.");
			return;
		}
		
		// If there is too much data on the disk, don't bother collecting any more.
		LocalyticsDatabase *db = [self db];
		if([db databaseSize] > MAX_DATABASE_SIZE) {
			LocalyticsLog("Database has exceeded the maximum size. Session not opened.");
			self.isSessionOpen = NO;
			return;
		}
		
		[self dequeueCloseEventBlobString];
		
		self.sessionActiveDuration = 0;
		self.sessionResumeTime = [NSDate date];
		self.unstagedFlowEvents = [NSMutableString string];
		self.stagedFlowEvents = [NSMutableString string];
		self.screens = [NSMutableString string];
		
		// Begin transaction for session open.
		NSString *t = @"open_session";
		BOOL success = [db beginTransaction:t];
		
		// lastSessionStartTimestamp isn't really the last session start time.
		// It's the sessionResumeTime which is [NSDate date] or now. Therefore,
		// save the current lastSessionTimestamp value from the database so it
		// can be used to calculate the elapsed time between session start times.
		NSTimeInterval previousSessionStartTimeInterval = [db lastSessionStartTimestamp];
		
		// Save session start time.
		self.lastSessionStartTimestamp = [self.sessionResumeTime timeIntervalSince1970];
		if (success) {
			success = [db setLastSessionStartTimestamp:self.lastSessionStartTimestamp];
		}
		
		// Retrieve next session number.
		int sessionNumber = 0;
		if (success) {
			success = [db incrementLastSessionNumber:&sessionNumber];
		}
		[self setSessionNumber:sessionNumber];
		
		if (success) {
			// Prepare session open event.
			self.sessionUUID = [self randomUUID];
			
			// Store event.
			NSMutableString *openEventString = [NSMutableString string];
			[openEventString appendString:@"{"];
			[openEventString appendString:[self formatAttributeWithName:PARAM_DATA_TYPE              value:@"s"              first:YES]];
			[openEventString appendString:[self formatAttributeWithName:PARAM_NEW_SESSION_UUID           value:self.sessionUUID]];
			[openEventString appendFormat:@",\"%@\":%ld", PARAM_CLIENT_TIME, (long)self.lastSessionStartTimestamp];
			[openEventString appendFormat:@",\"%@\":%d", PARAM_SESSION_NUMBER, sessionNumber];
			
			double elapsedTime = 0.0;
			if (previousSessionStartTimeInterval > 0) {
				elapsedTime = [self lastSessionStartTimestamp] - previousSessionStartTimeInterval;
			}
			NSString *elapsedTimeString = [NSString stringWithFormat:@"%.0f", elapsedTime];
			[openEventString appendString:[self formatAttributeWithName:PARAM_SESSION_ELAPSE_TIME value:elapsedTimeString]];
			
			[openEventString appendString:[self customDimensions]];
			[openEventString appendString:[self locationDimensions]];
			
			[openEventString appendString:@"}\n"];
			
			[self customDimensions];
			
			success = [db addEventWithBlobString:[[openEventString copy] autorelease]];
		}
		
		if (success) {
			[db releaseTransaction:t];
			self.isSessionOpen = YES;
			self.sessionHasBeenOpen = YES;
			LocalyticsLog("Succesfully opened session. UUID is: %@", self.sessionUUID);
         
            // Queue up a call to onStartSession after upload
            self.needsSessionStartActions = YES;
            
            // Upload after opening session successfully
            [self upload];
		}
		else {
			[db rollbackTransaction:t];
			self.isSessionOpen = NO;
			LocalyticsLog("Failed to open session.");
		}
	}
	@catch (NSException * e) {}
}

/*!
 @method reopenPreviousSession
 @abstract Reopens the previous session, using previous session variables. If there was no previous session, do nothing.
 */
- (void)reopenPreviousSession
{
	if(self.sessionHasBeenOpen == NO){
		LocalyticsLog("Unable to reopen previous session, because a previous session was never opened.");
		return;
	}
	
	// Record session resume time.
	self.sessionResumeTime = [NSDate date];
	
	//Remove close and flow events if they exist.
	[[self db] removeLastCloseAndFlowEvents];
	
	self.isSessionOpen = YES;
}

/*!
 @method addFlowEventWithName:type:
 @abstract Adds a simple key-value pair to the list of events tagged during this session.
 @param name The name of the tagged event.
 @param eventType A key representing the type of the tagged event. Either "s" for Screen or "e" for Event.
 */
- (void)addFlowEventWithName:(NSString *)name type:(NSString *)eventType
{
	if (!name || !eventType)
		return;
	
	// Format new event as simple key-value dictionary.
	NSString *eventString = [self formatAttributeWithName:eventType value:[self escapeString:name] first:YES];
	
	// Flow events are uploaded as a sequence of key-value pairs. Wrap the above in braces and append to the list.
	BOOL previousFlowEvents = self.unstagedFlowEvents.length > 0;
	if (previousFlowEvents) {
		[self.unstagedFlowEvents appendString:@","];
	}
	[self.unstagedFlowEvents appendFormat:@"{%@}", eventString];
}

/*!
 @method addScreenWithName:
 @abstract Adds a name to list of screens encountered during this session.
 @discussion The complete list of names is sent with the session close event. Screen names are stored in parallel to the
 screen flow events list and may be removed in future versions of this library.
 @param name The name of the tagged screen.
 */
- (void)addScreenWithName:(NSString *)name
{
	if (self.screens.length > 0) {
		[self.screens appendString:@","];
	}
	[self.screens appendFormat:@"\"%@\"", [self escapeString:name]];
}

/*!
 @method blobHeaderStringWithSequenceNumber:
 @abstract Creates the JSON string for the upload blob header, substituting in the given upload sequence number.
 @param  nextSequenceNumber The sequence number for the current upload attempt.
 @return The upload header JSON blob.
 */
- (NSString *)blobHeaderStringWithSequenceNumber:(int)nextSequenceNumber
{
	NSMutableString *headerString = [[[NSMutableString alloc] init] autorelease];
	
	// Common header information.
	//
	UIDevice *thisDevice = [UIDevice currentDevice];
	NSLocale *locale = [NSLocale currentLocale];
	NSLocale *english = [[[NSLocale alloc] initWithLocaleIdentifier: @"en_US"] autorelease];
	NSLocale *device_locale = [[NSLocale preferredLanguages] objectAtIndex:0];
	NSString *device_language = [english displayNameForKey:NSLocaleIdentifier value:device_locale];
	NSString *locale_country = [english displayNameForKey:NSLocaleCountryCode value:[locale objectForKey:NSLocaleCountryCode]];
	NSString *uuid = [self randomUUID];
	NSString *device_uuid = nil;
	NSString *device_first_adid = [[self db] firstAdid];
	NSString *device_current_adid = [LocalyticsDatapointHelper advertisingIdentifier];
    NSString *vendor_id = [LocalyticsDatapointHelper identifierForVendor];
    NSString *bundle_id = [LocalyticsDatapointHelper bundleIdentifier];
    
	// Open first level - blob information
	[headerString appendString:@"{"];
	[headerString appendFormat:@"\"%@\":%d", PARAM_SEQUENCE_NUMBER, nextSequenceNumber];
	[headerString appendFormat:@",\"%@\":%ld", PARAM_PERSISTED_AT, (long)[[self db] createdTimestamp]];
	[headerString appendString:[self formatAttributeWithName:PARAM_DATA_TYPE    value:@"h" ]];
	[headerString appendString:[self formatAttributeWithName:PARAM_UUID         value:uuid ]];
	
	// Open second level - blob header attributes
	[headerString appendString:[NSString stringWithFormat:@",\"%@\":{", PARAM_ATTRIBUTES]];
	[headerString appendString:[self formatAttributeWithName:PARAM_DATA_TYPE    value:@"a"  first:YES]];
	
	// >>  Application and session information
	//
	[headerString appendString:[self formatAttributeWithName:PARAM_INSTALL_ID       value:[self installationId] ]];
	[headerString appendString:[self formatAttributeWithName:PARAM_APP_KEY          value:self.applicationKey ]];
	[headerString appendString:[self formatAttributeWithName:PARAM_APP_VERSION      value:[LocalyticsDatapointHelper appVersion]  ]];
	[headerString appendString:[self formatAttributeWithName:PARAM_LIBRARY_VERSION  value:[self libraryVersion]        ]];
	
	// >>  Device Information
	//
	if (device_uuid) {
		[headerString appendString:[self formatAttributeWithName:PARAM_DEVICE_UUID_HASHED   value:[self hashString:device_uuid] ]];
	}
    
	if (self.advertisingIdentifierEnabled) {
		if (device_first_adid) {
			[headerString appendString:[self formatAttributeWithName:PARAM_DEVICE_ADID value:device_first_adid]];
		}
		if (device_current_adid) {
			[headerString appendString:[self formatAttributeWithName:PARAM_CURRENT_ADID value:device_current_adid]];
		}
	}
    
	if (vendor_id) {
		[headerString appendString:[self formatAttributeWithName:PARAM_VENDOR_ID value:vendor_id]];
	}
	if (bundle_id) {
		[headerString appendString:[self formatAttributeWithName:PARAM_BUNDLE_ID value:bundle_id]];
	}
	[headerString appendString:[NSString stringWithFormat:@",\"%@\":%@", PARAM_LIMIT_AD_TRACKING, [LocalyticsDatapointHelper advertisingTrackingEnabled] ? @"false" : @"true"]];
	[headerString appendString:[self formatAttributeWithName:PARAM_DEVICE_PLATFORM      value:[thisDevice model]            ]];
	[headerString appendString:[self formatAttributeWithName:PARAM_DEVICE_OS_VERSION    value:[thisDevice systemVersion]    ]];
	[headerString appendString:[self formatAttributeWithName:PARAM_DEVICE_MODEL         value:[LocalyticsDatapointHelper deviceModel]         ]];
	[headerString appendString:[NSString stringWithFormat:@",\"%@\":%lld", PARAM_DEVICE_MEMORY, (long long)[LocalyticsDatapointHelper availableMemory]  ]];
	[headerString appendString:[self formatAttributeWithName:PARAM_LOCALE_LANGUAGE   value:device_language]];
	[headerString appendString:[self formatAttributeWithName:PARAM_LOCALE_COUNTRY    value:locale_country]];
	[headerString appendString:[self formatAttributeWithName:PARAM_DEVICE_COUNTRY    value:[locale objectForKey:NSLocaleCountryCode]]];
	[headerString appendString:[NSString stringWithFormat:@",\"%@\":%@", PARAM_JAILBROKEN, [LocalyticsDatapointHelper isDeviceJailbroken] ? @"true" : @"false"]];
	[headerString appendString:[NSString stringWithFormat:@",\"%@\":%ld", PARAM_TIMEZONE_OFFSET, (long)[[NSTimeZone localTimeZone] secondsFromGMT]]];

    // >> Prod Push token
    //
    if (![[self db] isPushTokenNull])
    {
        NSString *pushToken = [[self db] pushToken];
        if (!pushToken) pushToken = @"";        
        [headerString appendString:[self formatAttributeWithName:PARAM_PUSH_TOKEN value:pushToken]];
    }

    // >> Dev Push token
    //
    if (![[self db] isDevPushTokenNull])
    {
        NSString *devPushToken = [[self db] devPushToken];
        if (!devPushToken) devPushToken = @"";
        [headerString appendString:[self formatAttributeWithName:PARAM_DEV_PUSH_TOKEN value:devPushToken]];
    }
    
	//  Close second level - attributes
	[headerString appendString:@"}"];
	
	// >> Custom Identifiers
	//
	NSDictionary *identifiers = [[self db] identifiers];
	if(identifiers != nil)
	{
		// Open third level - properties
		[headerString appendString:[NSString stringWithFormat:@",\"%@\":{", PARAM_IDENTIFIERS]];
		
		int i =0;
		for (id key in [identifiers allKeys])
		{
			// Have to escape paramName and paramValue because they user-defined.
			[headerString appendString:
			 [self formatAttributeWithName:[self escapeString:[key description]]
									 value:[self escapeString:[[identifiers valueForKey:key] description]]
									 first:(i == 0)]];
			i++;
		}
		
		// Close third level - properties
		[headerString appendString:@"}"];
	}
	
	// Close first level - blob information
	[headerString appendString:@"}\n"];
	
	return [[headerString copy] autorelease];
}

- (BOOL)ll_isOptedIn
{
	return [[self db] isOptedOut] == NO;
}

/*!
 @method createOptEvent:
 @abstract Generates the JSON for an opt event (user opting in or out) and writes it to the database.
 @return YES if the event was written to the database, NO otherwise
 */
- (BOOL)createOptEvent:(BOOL)optState
{
	// OptState is inversed. The JSON contains whether it is true that the user is opted out
	NSMutableString *optEventString = [NSMutableString string];
	[optEventString appendString:@"{"];
	[optEventString appendString:[self formatAttributeWithName:PARAM_DATA_TYPE  value:@"o"                  first:YES]];
	[optEventString appendString:[self formatAttributeWithName:PARAM_UUID         value:[self randomUUID] first:NO ]];
	[optEventString appendString:[NSString stringWithFormat:@",\"%@\":%@", PARAM_OPT_VALUE, (optState ? @"false" : @"true") ]];
	[optEventString appendFormat:@",\"%@\":%ld", PARAM_CLIENT_TIME, (long)[self currentTimestamp]];
	[optEventString appendString:@"}\n"];
	
	BOOL success = [[self db] addEventWithBlobString:[[optEventString copy] autorelease]];
	return success;
}

/*
 @method saveApplicationFlowAndRemoveOnResume:
 @abstract Constructs an application flow blob string and writes it to the database, optionally flagging it for deletion
 if the session is resumed.
 @param removeOnResume YES if the application flow blob should be deleted if the session is resumed.
 @return YES if the application flow event was written to the database successfully.
 */
- (BOOL)saveApplicationFlowAndRemoveOnResume:(BOOL)removeOnResume
{
#pragma unused(removeOnResume)
	BOOL success = YES;
	
	// If there are no new events, then there is nothing additional to save.
	if (self.unstagedFlowEvents.length) {
		// Flows are uploaded as a distinct blob type containing arrays of new and previously-uploaded event and
		// screen names. Write a flow event to the database.
		NSMutableString *flowEventString = [[[NSMutableString alloc] init] autorelease];
		
		// Open first level - flow blob event
		[flowEventString appendString:@"{"];
		[flowEventString appendString:[self formatAttributeWithName:PARAM_DATA_TYPE value:@"f"                  first:YES]];
		[flowEventString appendString:[self formatAttributeWithName:PARAM_UUID      value:[self randomUUID] ]];
		[flowEventString appendFormat:@",\"%@\":%ld", PARAM_SESSION_START, (long)self.lastSessionStartTimestamp];
		
		// Open second level - new flow events
		[flowEventString appendFormat:@",\"%@\":[", PARAM_NEW_FLOW_EVENTS];
		[flowEventString appendString:self.unstagedFlowEvents]; // Flow events are escaped in |-addFlowEventWithName:|
																// Close second level - new flow events
		[flowEventString appendString:@"]"];
		
		// Open second level - old flow events
		[flowEventString appendFormat:@",\"%@\":[", PARAM_OLD_FLOW_EVENTS];
		[flowEventString appendString:self.stagedFlowEvents];
		// Close second level - old flow events
		[flowEventString appendString:@"]"];
		
		// Close first level - flow blob event
		[flowEventString appendString:@"}\n"];
		
		success = [[self db] addFlowEventWithBlobString:[[flowEventString copy] autorelease]];
	}
	return success;
}

// Convenience method for formatAttributeWithName which sets firstAttribute to NO since
// this is the most common way to call it.
- (NSString *)formatAttributeWithName:(NSString *)paramName value:(NSString *)paramValue
{
	return [self formatAttributeWithName:paramName value:paramValue first:NO];
}

/*!
 @method formatAttributeWithName:value:firstAttribute:
 @abstract Returns the given string key/value pair as a JSON string.
 @param paramName The name of the parameter
 @param paramValue The value of the parameter
 @param firstAttribute YES if this attribute is first in an attribute list
 @return a JSON string which can be dumped to the JSON file
 */
- (NSString *)formatAttributeWithName:(NSString *)paramName value:(NSString *)paramValue first:(BOOL)firstAttribute
{
	// The expected result is one of:
	//  "paramname":"paramvalue"
	//  "paramname":null
	NSMutableString *formattedString = [NSMutableString string];
	if (!firstAttribute) {
		[formattedString appendString:@","];
	}
	
	NSString *quotedString = @"\"%@\"";
	paramName = [NSString stringWithFormat:quotedString, paramName];
	paramValue = paramValue ? [NSString stringWithFormat:quotedString, paramValue] : @"null";
	[formattedString appendFormat:@"%@:%@", paramName, paramValue];
	return [[formattedString copy] autorelease];
}

/*!
 @method escapeString
 @abstract Formats the input string so it fits nicely in a JSON document.  This includes
 escaping double quote and slash characters.
 @return The escaped version of the input string
 */
- (NSString *)escapeString:(NSString *)input
{
	NSMutableString *escapedString = [NSMutableString stringWithCapacity:[input length] * 2];
	for(int i = 0; i < [input length]; i++)
	{
		unichar currentChar = [input characterAtIndex:i];
		switch(currentChar)
		{
			case '\\':
				[escapedString appendString:@"\\\\"];
				break;
				
			case '\"':
				[escapedString appendString:@"\\\""];
				break;
				
			case '\t':
				[escapedString appendString:@"\\t"];
				break;
				
			case '\n':
				[escapedString appendString:@"\\n"];
				break;
				
			case '\r':
				[escapedString appendString:@"\\r"];
				break;
				
			case '\b':
				[escapedString appendString:@"\\b"];
				break;
				
			case '\f':
				[escapedString appendString:@"\\f"];
				break;
				
			default:
				if (currentChar < 0x20)
					[escapedString appendFormat:@"\\u%04x", currentChar];
				else
					[escapedString appendFormat:@"%C", currentChar];
		}
	}
	
	return [[escapedString copy] autorelease];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
	LocalyticsLog("Application entered the background.");
	
	// Continue executing until critical blocks finish executing or background time runs out, whichever comes first.
	UIApplication *application = (UIApplication *)[notification object];
	__block UIBackgroundTaskIdentifier taskID = [application beginBackgroundTaskWithExpirationHandler:^{
		// Synchronize with the main queue in case the the tasks finish at the same time as the expiration handler.
		dispatch_async(dispatch_get_main_queue(), ^{
			if (taskID != UIBackgroundTaskInvalid) {
				LocalyticsLog("Failed to finish executing critical tasks. Cleaning up.");
				[application endBackgroundTask:taskID];
				taskID = UIBackgroundTaskInvalid;
			}
		});
	}];
	
	// Critical tasks have finished. Expire the background task.
	dispatch_group_notify(_criticalGroup, dispatch_get_main_queue(), ^{
		LocalyticsLog("Finished executing critical tasks.");
		if (taskID != UIBackgroundTaskInvalid) {
			[application endBackgroundTask:taskID];
			taskID = UIBackgroundTaskInvalid;
		}
	});
}

#pragma mark Datapoint Functions
/*!
 @method customDimensions
 @abstract Returns the json blob containing the custom dimensions. Assumes this will be appended
 to an existing blob and as a result prepends the results with a comma.
 */
- (NSString *)customDimensions
{
	NSMutableString *dimensions = [[[NSMutableString alloc] init] autorelease];
	
	for(int i=0; i < 10; i++) {
		NSString *dimension = [[self db] customDimension:i];
		if(dimension) {
			[dimensions appendFormat:@",\"c%i\":\"%@\"", i, dimension];
		}
	}
	
	return [[dimensions copy] autorelease];
}

/*!
 @method locationDimensions
 @abstract Returns the json blob containing the current location if available or nil if no location is available.
 */
- (NSString *)locationDimensions
{
	if(lastDeviceLocation.latitude == 0 || lastDeviceLocation.longitude == 0) {
		return @"";
	}
	
	return [NSString stringWithFormat:@",\"lat\":%f,\"lng\":%f",
			lastDeviceLocation.latitude,
			lastDeviceLocation.longitude];
}

/*!
 @method hashString
 @abstract SHA1 Hashes a string
 */
- (NSString *)hashString:(NSString *)input
{
	NSData *stringBytes = [input dataUsingEncoding: NSUTF8StringEncoding];
	unsigned char digest[CC_SHA1_DIGEST_LENGTH];
	
	if (CC_SHA1([stringBytes bytes], (unsigned int)[stringBytes length], digest)) {
		NSMutableString* hashedUUID = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
		for(int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
			[hashedUUID appendFormat:@"%02x", digest[i]];
		}
		return hashedUUID;
	}
	
	return nil;
}

/*!
 @method randomUUID
 @abstract Generates a random UUID
 @return NSString containing the new UUID
 */
- (NSString *)randomUUID
{
	CFUUIDRef theUUID = CFUUIDCreate(NULL);
	CFStringRef stringUUID = CFUUIDCreateString(NULL, theUUID);
	CFRelease(theUUID);
	return [(NSString *)stringUUID autorelease];
}

/*!
 @method installationId
 @abstract Returns the install id from the database
 @return A string uniquely identifying this installation of this app
 */
- (NSString *)installationId
{
    return [[self db] installId];
}

- (NSString *)customDimension:(int)dimension
{
	__block NSString *customDimension;
	
	dispatch_sync(self.queue, ^{
		@try {
			customDimension = [self.db customDimension:dimension];
		}
		@catch (NSException *e) {}
	});
	
	return customDimension;
}

/*!
 @method currentTimestamp
 @abstract Gets the current time as seconds since Unix epoch.
 @return an NSTimeInterval time.
 */
- (NSTimeInterval)currentTimestamp
{
	return [[NSDate date] timeIntervalSince1970];
}

/*!
 @method appKeyIsValid
 @abstract Reports whether the appKey is correctly formatted
 @return A bool with the state of the app key.
 */
+ (BOOL)appKeyIsValid:(NSString *)appKey
{
	if(!appKey || appKey.length == 0)
		return NO;
	
	NSPredicate *matchPred = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", @"[A-Fa-f0-9-]+"];
	return [matchPred evaluateWithObject:appKey];
}

- (LocalyticsDatabase *)db
{
	@synchronized(self) {
		if (_db == nil) {
			_db = [[LocalyticsDatabase alloc] init];
		}
	}
	return _db;
}

- (LocalyticsUploader *)uploader
{
	@synchronized(self) {
		if (_uploader == nil) {
			_uploader = [[LocalyticsUploader alloc] init];
		}
	}
	return _uploader;
}


#pragma mark System Functions
+ (id)allocWithZone:(NSZone *)zone {
	@synchronized(self) {
		if (_sharedLocalyticsSession == nil) {
			_sharedLocalyticsSession = [super allocWithZone:zone];
			return _sharedLocalyticsSession;
		}
	}
	// returns nil on subsequent allocations
	return nil;
}

- (id)copyWithZone:(NSZone *)zone
{
#pragma unused(zone)
	return self;
}

- (id)retain
{
	return self;
}

- (NSUInteger)retainCount
{
	// maximum value of an unsigned int - prevents additional retains for the class
	return UINT_MAX;
}

// Ignore release commands
- (oneway void)release {}

- (id)autorelease
{
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
	
	dispatch_release(_criticalGroup);
	dispatch_release(_queue);
	[_sessionUUID release];
	[_applicationKey release];
	[_sessionCloseTime release];
	[_unstagedFlowEvents release];
	[_stagedFlowEvents release];
	[_screens release];
	[_sharedLocalyticsSession release];
	[_localyticsDelegate release];
	
	[super dealloc];
}

@end
