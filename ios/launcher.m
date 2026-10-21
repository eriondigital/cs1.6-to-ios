/*
 launcher.m - iOS launcher for the Counter-Strike 1.6 port
 Replaces engine/platform/ios/launchdialog.m from Xash3D FWGS at build time.

 Based on launchdialog.m, Copyright (C) 2016 mittorn

 What it does differently from the stock Xash3D FWGS dialog:
  - no "launch options" prompt, the game starts straight into Counter-Strike
    with YaPB bots enabled (-game cstrike -dll dlls/yapb_ios_<arch>.dylib);
  - gets the player's own game files in with as little effort as possible:
      * a "Choose Game Files" button to pick valve/cstrike zips from anywhere
        (Downloads, iCloud Drive, AirDrop...),
      * zips dropped into the app's folder or opened with the app are unpacked
        automatically,
      * folders are recognised by their contents and moved into place, so
        "cstrike 2", "Counter-Strike 1.6/valve" or a zip without a top folder
        all work;
  - tells YaPB where the game libraries live (inside the signed app bundle,
    not in Documents) through XASH3D_GAMELIBDIR;
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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "zipimport.h"

static int szArgc;
static char **szArgv;
float g_iOSVer;

static UIWindow *g_window;
static UIViewController *g_controller;
static UIAlertController *g_progressAlert;
static volatile BOOL g_dialogDone;
static int g_choice;
static NSMutableSet *g_failedZips;

static NSString *const kHelpFileName = @"HOW TO ADD GAME FILES.txt";
static NSString *const kCommandLineFileName = @"commandline.txt";
static NSString *const kImportDirName = @".import";

enum
{
	kChoiceChooseFiles = 0,
	kChoiceCheckAgain = 1
};

typedef enum
{
	kFolderOther = 0,
	kFolderValve,
	kFolderCstrike
} folder_kind_t;

typedef struct import_progress_s
{
	char name[256];
	int lastpct;
} import_progress_t;

/*
=============================================================================

	PATHS

=============================================================================
*/
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

static BOOL IsDirectory( NSString *path )
{
	BOOL isDir = NO;
	return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && isDir;
}

static NSString *FindChild( NSString *dir, NSString *name, BOOL wantDir )
{
	for( NSString *item in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] )
	{
		if( [item caseInsensitiveCompare:name] == NSOrderedSame )
		{
			NSString *full = [dir stringByAppendingPathComponent:item];

			if( IsDirectory( full ) == wantDir )
				return full;
		}
	}

	return nil;
}

static BOOL HasGameData( NSString *docs )
{
	return FindChild( docs, @"valve", YES ) != nil && FindChild( docs, @"cstrike", YES ) != nil;
}

/*
=============================================================================

	FINDING THE GAME FOLDERS

=============================================================================
*/
// value of the game "..." key in liblist.gam, or nil
static NSString *LiblistGameName( NSString *dir )
{
	NSString *liblist = FindChild( dir, @"liblist.gam", NO );
	NSString *text;

	if( !liblist )
		return nil;

	text = [NSString stringWithContentsOfFile:liblist encoding:NSISOLatin1StringEncoding error:nil];

	for( NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] )
	{
		NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		NSArray *parts = [trimmed componentsSeparatedByString:@"\""];

		if( [parts count] >= 3 && [[parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] caseInsensitiveCompare:@"game"] == NSOrderedSame )
			return parts[1];
	}

	return nil;
}

static folder_kind_t ClassifyFolder( NSString *path )
{
	NSString *name = [[path lastPathComponent] lowercaseString];
	NSString *game;

	if( [name isEqualToString:@"valve"] )
		return kFolderValve;

	if( [name isEqualToString:@"cstrike"] )
		return kFolderCstrike;

	game = LiblistGameName( path );

	if( game && [game caseInsensitiveCompare:@"Counter-Strike"] == NSOrderedSame )
		return kFolderCstrike;

	if( game && [game caseInsensitiveCompare:@"Half-Life"] == NSOrderedSame )
		return kFolderValve;

	if( !game && FindChild( path, @"cstrike.wad", NO ))
		return kFolderCstrike;

	if( !game && FindChild( path, @"halflife.wad", NO ))
		return kFolderValve;

	return kFolderOther;
}

// Looks for the valve and cstrike folders below dir, shallowest first.
static void FindGameFolders( NSString *dir, int depth, NSString **valve, NSString **cstrike )
{
	NSArray *children = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector( compare: )];
	NSMutableArray *others = [NSMutableArray array];

	for( NSString *child in children )
	{
		NSString *full = [dir stringByAppendingPathComponent:child];
		folder_kind_t kind;

		if( [child hasPrefix:@"."] || !IsDirectory( full ))
			continue;

		kind = ClassifyFolder( full );

		if( kind == kFolderValve )
		{
			if( !*valve )
				*valve = full;
		}
		else if( kind == kFolderCstrike )
		{
			if( !*cstrike )
				*cstrike = full;
		}
		else
		{
			[others addObject:full];
		}
	}

	if( depth <= 0 )
		return;

	for( NSString *other in others )
		FindGameFolders( other, depth - 1, valve, cstrike );
}

static BOOL SameItem( NSString *a, NSString *b )
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSDictionary *aa, *ba;

	if( [a caseInsensitiveCompare:b] == NSOrderedSame )
		return YES;

	aa = [fm attributesOfItemAtPath:a error:nil];
	ba = [fm attributesOfItemAtPath:b error:nil];

	return aa && ba && [aa fileSystemNumber] == [ba fileSystemNumber] && [aa fileSystemFileNumber] == [ba fileSystemFileNumber];
}

// Moves src to dst. When dst already exists, moves over whatever it doesn't have yet.
static void MergeMove( NSString *src, NSString *dst )
{
	NSFileManager *fm = [NSFileManager defaultManager];

	if( SameItem( src, dst ))
		return;

	if( ![fm fileExistsAtPath:dst] )
	{
		[fm moveItemAtPath:src toPath:dst error:nil];
		return;
	}

	if( !IsDirectory( src ) || !IsDirectory( dst ))
		return; // keep what is already there

	for( NSString *child in [fm contentsOfDirectoryAtPath:src error:nil] )
		MergeMove( [src stringByAppendingPathComponent:child], [dst stringByAppendingPathComponent:child] );

	if( [[fm contentsOfDirectoryAtPath:src error:nil] count] == 0 )
		[fm removeItemAtPath:src error:nil];
}

static void PlaceGameFolders( NSString *docs, NSString *valve, NSString *cstrike )
{
	if( valve )
		MergeMove( valve, [docs stringByAppendingPathComponent:@"valve"] );

	if( cstrike )
		MergeMove( cstrike, [docs stringByAppendingPathComponent:@"cstrike"] );
}

// Puts the player's folders where the engine expects them: Documents/valve and Documents/cstrike.
static void NormalizeGameFolders( NSString *docs )
{
	NSString *valve = nil, *cstrike = nil;

	FindGameFolders( docs, 3, &valve, &cstrike );
	PlaceGameFolders( docs, valve, cstrike );
}

/*
=============================================================================

	UI

=============================================================================
*/
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

static void RunUntilDone( void )
{
	@autoreleasepool
	{
		while( !g_dialogDone )
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
	}
}

// lets a dismiss animation finish before something else is presented
static void SettleUI( void )
{
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
}

static void ShowAlert( NSString *title, NSString *message, NSArray *buttons )
{
	UIAlertController *alert;
	NSUInteger i;

	PrepareWindow();
	alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];

	for( i = 0; i < [buttons count]; i++ )
	{
		int choice = (int)i;

		[alert addAction:[UIAlertAction actionWithTitle:buttons[i] style:UIAlertActionStyleDefault
			handler:^( UIAlertAction *action ) { g_choice = choice; g_dialogDone = YES; }]];
	}

	g_choice = 0;
	g_dialogDone = NO;
	[g_controller presentViewController:alert animated:YES completion:nil];
	RunUntilDone();
	SettleUI();
}

static void ShowProgress( NSString *title, NSString *message )
{
	PrepareWindow();

	if( g_progressAlert )
	{
		g_progressAlert.title = title;
		g_progressAlert.message = message;
		return;
	}

	// kept alive by the presenting controller while on screen
	g_progressAlert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
	[g_controller presentViewController:g_progressAlert animated:YES completion:nil];
}

static void HideProgress( void )
{
	if( !g_progressAlert )
		return;

	[g_progressAlert dismissViewControllerAnimated:YES completion:nil];
	g_progressAlert = nil;
	SettleUI();
}

@interface CS16FilePicker : NSObject <UIDocumentPickerDelegate>
@end

@implementation CS16FilePicker

// import mode: the picked files are copies in our sandbox, move them into Documents
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray *)urls
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *docs = DocumentsPath();

	for( NSURL *url in urls )
	{
		NSURL *dst = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:[url lastPathComponent]]];

		[fm removeItemAtURL:dst error:nil];
		if( ![fm moveItemAtURL:url toURL:dst error:nil] )
			[fm copyItemAtURL:url toURL:dst error:nil];
	}

	g_dialogDone = YES;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url
{
	[self documentPicker:controller didPickDocumentsAtURLs:@[ url ]];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
	g_dialogDone = YES;
}

@end

static void ChooseGameFiles( void )
{
	static CS16FilePicker *delegate = nil;
	UIDocumentPickerViewController *picker;

	if( !delegate )
		delegate = [[CS16FilePicker alloc] init];

	PrepareWindow();
	picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.zip-archive", @"com.pkware.zip-archive" ] inMode:UIDocumentPickerModeImport];
	picker.delegate = delegate;
	picker.allowsMultipleSelection = YES;

	g_dialogDone = NO;
	[g_controller presentViewController:picker animated:YES completion:nil];
	RunUntilDone();
	SettleUI();
}

static void ShowMissingDataAlert( NSString *docs )
{
	BOOL haveValve = FindChild( docs, @"valve", YES ) != nil;
	BOOL haveCstrike = FindChild( docs, @"cstrike", YES ) != nil;
	NSString *status = @"";
	NSString *message;

	if( haveValve && !haveCstrike )
		status = @"Found \"valve\", still missing \"cstrike\".\n\n";
	else if( haveCstrike && !haveValve )
		status = @"Found \"cstrike\", still missing \"valve\".\n\n";

	message = [NSString stringWithFormat:
		@"This app needs your own Counter-Strike 1.6 game files: the \"valve\" and \"cstrike\" folders "
		@"from your PC install, zipped or not.\n\n%@"
		@"Tap Choose Game Files and pick the zips (from Downloads, iCloud Drive, AirDrop...), "
		@"or copy the folders into Files > On My iPhone > CS 1.6.", status];

	ShowAlert( @"Add your game files", message, @[ @"Choose Game Files", @"Check Again" ] );
}

/*
=============================================================================

	ZIP IMPORT

=============================================================================
*/
static void ImportProgress( void *ctx, unsigned long long done, unsigned long long total )
{
	import_progress_t *prog = ctx;
	int pct = total ? (int)( done * 100 / total ) : 100;

	if( pct == prog->lastpct )
		return;

	prog->lastpct = pct;

	@autoreleasepool
	{
		NSString *message = [NSString stringWithFormat:@"Unpacking %s ... %d%%", prog->name, pct];

		dispatch_async( dispatch_get_main_queue(), ^{
			if( g_progressAlert )
				g_progressAlert.message = message;
		});
	}
}

static NSString *ZipKey( NSString *path )
{
	NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
	return [NSString stringWithFormat:@"%@|%llu|%@", path, [attrs fileSize], [attrs fileModificationDate]];
}

static NSArray *FindZips( NSString *docs )
{
	NSMutableArray *zips = [NSMutableArray array];
	NSArray *dirs = @[ docs, [docs stringByAppendingPathComponent:@"Inbox"] ];

	for( NSString *dir in dirs )
	{
		for( NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] )
		{
			NSString *full = [dir stringByAppendingPathComponent:name];

			if( [name hasPrefix:@"."] || [[name pathExtension] caseInsensitiveCompare:@"zip"] != NSOrderedSame || IsDirectory( full ))
				continue;

			if( [g_failedZips containsObject:ZipKey( full )] )
				continue;

			[zips addObject:full];
		}
	}

	return zips;
}

// Unpacks game zips found in Documents (or Documents/Inbox) and moves the game folders into place.
// Returns YES when something was imported.
static BOOL ImportZips( NSString *docs )
{
	static char errbuf[512];
	static import_progress_t prog;
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *importRoot = [docs stringByAppendingPathComponent:kImportDirName];
	NSArray *zips = FindZips( docs );
	NSUInteger i;
	BOOL imported = NO;

	if( ![zips count] )
		return NO;

	if( !g_failedZips )
		g_failedZips = [[NSMutableSet alloc] init];

	[fm removeItemAtPath:importRoot error:nil];

	for( i = 0; i < [zips count]; i++ )
	{
		NSString *zip = zips[i];
		NSString *dest = [importRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu", (unsigned long)i]];
		NSString *valve = nil, *cstrike = nil;
		folder_kind_t rootKind;
		char *zippath = strdup( [zip fileSystemRepresentation] );
		char *destpath = strdup( [dest fileSystemRepresentation] );
		__block int result = 0;

		snprintf( prog.name, sizeof( prog.name ), "%s", [[zip lastPathComponent] UTF8String] );
		prog.lastpct = -1;
		errbuf[0] = '\0';

		ShowProgress( @"Preparing game files", [NSString stringWithFormat:@"Unpacking %@ ...", [zip lastPathComponent]] );

		g_dialogDone = NO;
		dispatch_async( dispatch_get_global_queue( QOS_CLASS_USER_INITIATED, 0 ), ^{
			int r = ZipImport_Extract( zippath, destpath, ImportProgress, &prog, errbuf, sizeof( errbuf ));

			dispatch_async( dispatch_get_main_queue(), ^{
				result = r;
				g_dialogDone = YES;
			});
		});
		RunUntilDone();

		free( zippath );
		free( destpath );

		if( result != 0 )
		{
			NSLog( @"Import of %@ failed: %s", zip, errbuf );
			HideProgress();
			[fm removeItemAtPath:importRoot error:nil];
			[g_failedZips addObject:ZipKey( zip )];
			ShowAlert( @"Couldn't unpack the game files",
				[NSString stringWithFormat:@"%@: %s\n\nTry copying the zip again.", [zip lastPathComponent], errbuf],
				@[ @"OK" ] );
			continue;
		}

		// a zip of the folder itself has the game files at its root
		rootKind = ClassifyFolder( dest );
		if( rootKind == kFolderValve )
			valve = dest;
		else if( rootKind == kFolderCstrike )
			cstrike = dest;
		else
			FindGameFolders( dest, 3, &valve, &cstrike );

		if( valve || cstrike )
		{
			PlaceGameFolders( docs, valve, cstrike );
			[fm removeItemAtPath:zip error:nil]; // unpacked, no need to keep a second copy
			imported = YES;
			NSLog( @"Imported game files from %@", zip );
		}
		else
		{
			NSLog( @"%@ has no Counter-Strike game folders, leaving it alone", zip );
			[g_failedZips addObject:ZipKey( zip )];
		}

		[fm removeItemAtPath:dest error:nil];
	}

	HideProgress();
	[fm removeItemAtPath:importRoot error:nil];

	return imported;
}

/*
=============================================================================

	LAUNCH

=============================================================================
*/
// The app's folder only shows up in the Files app once it has something in it,
// so leave a short note there on first launch.
static void WriteHelpFile( NSString *docs )
{
	NSString *path = [docs stringByAppendingPathComponent:kHelpFileName];

	if( [[NSFileManager defaultManager] fileExistsAtPath:path] )
		return;

	NSString *text =
		@"Counter-Strike 1.6 for iOS\n"
		@"==========================\n\n"
		@"This app is the game engine only. It needs your own Counter-Strike 1.6 game files:\n"
		@"the \"valve\" and \"cstrike\" folders of your PC install\n"
		@"(Steam: Steam/steamapps/common/Half-Life/).\n\n"
		@"Easiest: zip the two folders, send the zip(s) to your phone, open the app and tap\n"
		@"\"Choose Game Files\". Or put the zips or the folders into this folder\n"
		@"(Files > On My iPhone > CS 1.6) and open the app. Zips are unpacked automatically.\n\n"
		@"Optional: put extra launch options in a file named commandline.txt in this folder,\n"
		@"for example:  -ref gles3compat\n\n"
		@"If something goes wrong, engine.log in this folder has the details.\n";

	[text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// YaPB (which loads the CS game library) lives in the app bundle. Its path is passed explicitly:
// with "-dll @yapb" the engine builds the path from liblist.gam's gamedll folder, and many packs
// point that at metamod (addons/metamod/dlls/...), where our library isn't.
static NSString *ServerLibraryArg( void )
{
	NSString *dlls = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"cstrike/dlls"];

	for( NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dlls error:nil] )
	{
		if( [name hasPrefix:@"yapb_ios_"] && [name hasSuffix:@".dylib"] )
			return [@"dlls" stringByAppendingPathComponent:name];
	}

	return @"@yapb";
}

static NSArray *ReadExtraArgs( NSString *docs )
{
	NSMutableArray *args = [NSMutableArray array];
	NSString *text = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:kCommandLineFileName] encoding:NSUTF8StringEncoding error:nil];

	if( !text )
		return args;

	for( NSString *token in [text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] )
	{
		if( [token length] > 0 )
			[args addObject:token];
	}

	return args;
}

void IOS_LaunchDialog( void )
{
	NSString *ver = [[UIDevice currentDevice] systemVersion];
	NSString *docs = DocumentsPath();
	NSString *gameLibDir;
	NSMutableArray *args;
	int count, i;

	g_iOSVer = [ver floatValue];
	NSLog( @"System Version is %@", ver );

	// voice chat on servers needs the microphone, asking up front avoids a crash later
	[[AVAudioSession sharedInstance] requestRecordPermission:^( BOOL granted ) {}];

	// logs and relative paths (YaPB writes its data relative to cwd) go to Documents
	[[NSFileManager defaultManager] changeCurrentDirectoryPath:docs];

	WriteHelpFile( docs );

	while( 1 )
	{
		NormalizeGameFolders( docs );

		if( HasGameData( docs ))
			break;

		if( ImportZips( docs ))
			continue;

		ShowMissingDataAlert( docs );

		if( g_choice == kChoiceChooseFiles )
			ChooseGameFiles();
	}

	if( g_window )
	{
		g_window.hidden = YES;
		g_window = nil;
		g_controller = nil;
	}

	NSLog( @"Game data found in %@", docs );

	// game libraries are inside the signed bundle, tell YaPB where to find the CS server library
	gameLibDir = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"cstrike/dlls"];
	setenv( "XASH3D_GAMELIBDIR", [gameLibDir fileSystemRepresentation], 1 );

	// user arguments go first, the engine uses the first occurrence of a parameter
	args = [NSMutableArray arrayWithArray:ReadExtraArgs( docs )];
	[args addObjectsFromArray:@[ @"-game", @"cstrike", @"-dll", ServerLibraryArg(), @"-log" ]];

	count = (int)[args count];
	szArgv = calloc( count + 2, sizeof( char * ));
	szArgv[0] = strdup( [[[NSBundle mainBundle] executablePath] fileSystemRepresentation] );

	for( i = 0; i < count; i++ )
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
