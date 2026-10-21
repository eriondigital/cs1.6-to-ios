/*
 launcher.m - iOS launcher for the Counter-Strike 1.6 port
 Replaces engine/platform/ios/launchdialog.m from Xash3D FWGS at build time.

 Based on launchdialog.m, Copyright (C) 2016 mittorn

 What it does differently from the stock Xash3D FWGS dialog:
  - no "launch options" prompt, the game starts straight into Counter-Strike
    with YaPB bots enabled (-game cstrike -dll @yapb);
  - checks that the player copied the "valve" and "cstrike" folders into the
    app's Documents folder (visible in the Files app) and explains how to do it
    when they are missing;
  - finds the game files even if they were copied inside an extra folder,
    e.g. "Counter-Strike 1.6/valve";
  - tells YaPB where the game libraries live (they're inside the signed app
    bundle, not in Documents) through XASH3D_GAMELIBDIR;
  - optional extra arguments can be put in Documents/commandline.txt.

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
*/

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#include <stdlib.h>
#include <string.h>

static int szArgc;
static char **szArgv;
float g_iOSVer;

static UIWindow *g_window;
static UIViewController *g_controller;
static volatile BOOL g_dialogDone;

static NSString *const kHelpFileName = @"HOW TO ADD GAME FILES.txt";
static NSString *const kCommandLineFileName = @"commandline.txt";

static NSString *DocumentsPath( void )
{
	NSArray *paths = NSSearchPathForDirectoriesInDomains( NSDocumentDirectory, NSUserDomainMask, YES );
	NSString *docs = [paths objectAtIndex:0];
	[[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
	return docs;
}

const char *IOS_GetDocsDir( void )
{
	static char *dir = NULL;

	if( dir )
		return dir;

	// keep our own copy, fileSystemRepresentation is autoreleased
	dir = strdup( [DocumentsPath() fileSystemRepresentation] );
	NSLog( @"IOS_GetDocsDir: %s", dir );

	return dir;
}

const char *IOS_GetExecDir( void )
{
	static char *dir = NULL;

	if( dir )
		return dir;

	dir = strdup( [[[NSBundle mainBundle] bundlePath] fileSystemRepresentation] );
	NSLog( @"IOS_GetExecDir: %s", dir );

	return dir;
}

static NSString *FindChildCaseInsensitive( NSString *dir, NSString *name )
{
	NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];

	for( NSString *item in items )
	{
		if( [item caseInsensitiveCompare:name] == NSOrderedSame )
		{
			NSString *full = [dir stringByAppendingPathComponent:item];
			BOOL isDir = NO;

			if( [[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir] && isDir )
				return full;
		}
	}

	return nil;
}

static BOOL HasGameData( NSString *root )
{
	return FindChildCaseInsensitive( root, @"valve" ) != nil && FindChildCaseInsensitive( root, @"cstrike" ) != nil;
}

// Looks for a folder that holds both "valve" and "cstrike": Documents itself,
// or up to two levels below it (unzipping in the Files app usually adds one).
static NSString *FindGameRoot( void )
{
	NSString *docs = DocumentsPath();
	NSFileManager *fm = [NSFileManager defaultManager];

	if( HasGameData( docs ))
		return docs;

	for( NSString *child in [fm contentsOfDirectoryAtPath:docs error:nil] )
	{
		NSString *level1 = [docs stringByAppendingPathComponent:child];
		BOOL isDir = NO;

		if( [child hasPrefix:@"."] || ![fm fileExistsAtPath:level1 isDirectory:&isDir] || !isDir )
			continue;

		if( HasGameData( level1 ))
			return level1;

		for( NSString *grandchild in [fm contentsOfDirectoryAtPath:level1 error:nil] )
		{
			NSString *level2 = [level1 stringByAppendingPathComponent:grandchild];

			if( [grandchild hasPrefix:@"."] || ![fm fileExistsAtPath:level2 isDirectory:&isDir] || !isDir )
				continue;

			if( HasGameData( level2 ))
				return level2;
		}
	}

	return nil;
}

// The app's folder only shows up in the Files app once it has something in it,
// so leave a short note there on first launch.
static void WriteHelpFile( void )
{
	NSString *path = [DocumentsPath() stringByAppendingPathComponent:kHelpFileName];

	if( [[NSFileManager defaultManager] fileExistsAtPath:path] )
		return;

	NSString *text =
		@"Counter-Strike 1.6 for iOS\n"
		@"==========================\n\n"
		@"This app is the game engine only. Copy your own Counter-Strike 1.6 game files here:\n\n"
		@"  1. Find the \"valve\" and \"cstrike\" folders of your Counter-Strike 1.6 install\n"
		@"     (Steam: Steam/steamapps/common/Half-Life/).\n"
		@"  2. Copy BOTH folders into this folder (Files > On My iPhone > CS 1.6),\n"
		@"     so you end up with:\n"
		@"        CS 1.6/valve/...\n"
		@"        CS 1.6/cstrike/...\n"
		@"  3. Open the app.\n\n"
		@"Tip: you can copy a .zip of the two folders here and tap it in Files to unzip it.\n\n"
		@"Optional: put extra launch options in a file named commandline.txt in this folder,\n"
		@"for example:  -ref gles3compat\n\n"
		@"If something goes wrong, engine.log in this folder has the details.\n";

	[text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void PrepareWindow( void )
{
	if( g_window )
		return;

	g_window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
	g_controller = [[UIViewController alloc] init];
	[g_controller.view setBackgroundColor:[UIColor blackColor]];
	[g_window setRootViewController:g_controller];
	[g_window makeKeyAndVisible];
}

static void ShowMissingDataAlert( void )
{
	NSString *message =
		@"This app needs your own Counter-Strike 1.6 game files.\n\n"
		@"Copy the \"valve\" and \"cstrike\" folders from your Counter-Strike 1.6 install into:\n\n"
		@"Files > On My iPhone > CS 1.6\n\n"
		@"Then tap Check Again.";

	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Game files needed"
		message:message
		preferredStyle:UIAlertControllerStyleAlert];

	[alert addAction:[UIAlertAction actionWithTitle:@"Check Again" style:UIAlertActionStyleDefault
		handler:^( UIAlertAction *action ) { g_dialogDone = YES; }]];

	g_dialogDone = NO;
	[g_controller presentViewController:alert animated:YES completion:nil];

	@autoreleasepool
	{
		while( !g_dialogDone )
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
	}

	// let the dismiss animation finish before the next presentation
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
}

static NSArray *ReadExtraArgs( NSString *gameRoot )
{
	NSMutableArray *args = [NSMutableArray array];
	NSArray *candidates = @[ [DocumentsPath() stringByAppendingPathComponent:kCommandLineFileName],
		[gameRoot stringByAppendingPathComponent:kCommandLineFileName] ];

	for( NSString *path in candidates )
	{
		NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];

		if( !text )
			continue;

		NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
		for( NSString *token in [text componentsSeparatedByCharactersInSet:ws] )
		{
			if( [token length] > 0 )
				[args addObject:token];
		}
		break;
	}

	return args;
}

void IOS_LaunchDialog( void )
{
	NSString *ver = [[UIDevice currentDevice] systemVersion];
	g_iOSVer = [ver floatValue];
	NSLog( @"System Version is %@", ver );

	// voice chat on servers needs the microphone, asking up front avoids a crash later
	[[AVAudioSession sharedInstance] requestRecordPermission:^( BOOL granted ) {}];

	NSString *docs = DocumentsPath();

	// logs and relative paths (YaPB writes its data relative to cwd) go to Documents
	[[NSFileManager defaultManager] changeCurrentDirectoryPath:docs];

	WriteHelpFile();

	NSString *gameRoot = FindGameRoot();

	while( !gameRoot )
	{
		PrepareWindow();
		ShowMissingDataAlert();
		gameRoot = FindGameRoot();
	}

	if( g_window )
	{
		g_window.hidden = YES;
		g_window = nil;
		g_controller = nil;
	}

	NSLog( @"Game data found in %@", gameRoot );

	if( ![gameRoot isEqualToString:docs] )
	{
		// engine checks this before falling back to IOS_GetDocsDir()
		setenv( "XASH3D_BASEDIR", [gameRoot fileSystemRepresentation], 1 );
		[[NSFileManager defaultManager] changeCurrentDirectoryPath:gameRoot];
	}

	// game libraries are inside the signed bundle, tell YaPB where to find the CS server library
	NSString *gameLibDir = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"cstrike/dlls"];
	setenv( "XASH3D_GAMELIBDIR", [gameLibDir fileSystemRepresentation], 1 );

	// user arguments go first, the engine uses the first occurrence of a parameter
	NSMutableArray *args = [NSMutableArray arrayWithArray:ReadExtraArgs( gameRoot )];
	[args addObjectsFromArray:@[ @"-game", @"cstrike", @"-dll", @"@yapb", @"-log" ]];

	int count = (int)[args count];
	szArgv = calloc( count + 2, sizeof( char * ));
	szArgv[0] = strdup( [[[NSBundle mainBundle] executablePath] fileSystemRepresentation] );

	for( int i = 0; i < count; i++ )
		szArgv[i + 1] = strdup( [args[i] UTF8String] );

	szArgc = count + 1;
	szArgv[szArgc] = NULL;

	NSLog( @"Launching with: %@", [args componentsJoinedByString:@" "] );
}

char *IOS_GetUDID( void )
{
	static char udid[256];
	NSString *uuid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];

	strncpy( udid, uuid ? [uuid UTF8String] : "unknown", sizeof( udid ) - 1 );
	udid[sizeof( udid ) - 1] = 0;
	return udid;
}

void IOS_Log( const char *text )
{
	NSLog( @"Xash: %@", [NSString stringWithUTF8String:text] );
}

int IOS_GetArgs( char ***out )
{
	*out = szArgv;
	return szArgc;
}
