
#import <AppKit/AppKit.h>
#import "SUInstaller.h"
#import "SUHost.h"
#import "SUStandardVersionComparator.h"
#import "SUStatusController.h"
#import "SUPlainInstallerInternals.h"

#include <unistd.h>

#define	LONG_INSTALLATION_TIME			1.2				// If the Installation takes longer than this time the Application Icon is shown in the Dock so that the user has some feedback.
#define	CHECK_FOR_PARENT_TO_QUIT_TIME	.5				// Time this app uses to recheck if the parent has already died.
										
@interface TerminationListener : NSObject
{
	const char		*executablepath;
	pid_t			parentprocessid;
	const char		*folderpath;
	NSString		*selfPath;
	NSTimer			*watchdogTimer;
	NSTimer			*longInstallationTimer;
	SUHost			*host;
}

- (void) parentHasQuit;

- (void) relaunch;
- (void) install;

- (void) showAppIconInDock:(NSTimer *)aTimer;
- (void) watchdog:(NSTimer *)aTimer;

@end

@implementation TerminationListener

- (id) initWithExecutablePath:(const char *)execpath parentProcessId:(pid_t)ppid folderPath: (const char*)infolderpath
		selfPath: (NSString*)inSelfPath
{
	if( !(self = [super init]) )
		return nil;
	
	executablepath	= execpath;
	parentprocessid	= ppid;
	folderpath		= infolderpath;
	selfPath		= [inSelfPath retain];
	
	BOOL	alreadyTerminated = (getppid() == 1); // ppid is launchd (1) => parent terminated already
	
	if( alreadyTerminated )
		[self parentHasQuit];
	else
		watchdogTimer = [[NSTimer scheduledTimerWithTimeInterval:CHECK_FOR_PARENT_TO_QUIT_TIME target:self selector:@selector(watchdog:) userInfo:nil repeats:YES] retain];

	return self;
}


-(void)	dealloc
{
	[longInstallationTimer invalidate];
	[longInstallationTimer release];
	longInstallationTimer = nil;

	[selfPath release];
	selfPath = nil;

	[watchdogTimer release];
	watchdogTimer = nil;

	[host release];
	host = nil;
	
	[super dealloc];
}


-(void)	parentHasQuit
{
	[watchdogTimer invalidate];
	longInstallationTimer = [[NSTimer scheduledTimerWithTimeInterval: LONG_INSTALLATION_TIME
								target: self selector: @selector(showAppIconInDock:)
								userInfo:nil repeats:NO] retain];

	if( folderpath )
		[self install];
	else
		[self relaunch];
}

- (void) watchdog:(NSTimer *)aTimer
{
	ProcessSerialNumber psn;
	if (GetProcessForPID(parentprocessid, &psn) == procNotFound)
		[self parentHasQuit];
}

- (void)showAppIconInDock:(NSTimer *)aTimer;
{
	ProcessSerialNumber		psn = { 0, kCurrentProcess };
	TransformProcessType( &psn, kProcessTransformToForegroundApplication );
}


- (void) relaunch
{
	NSString	*appPath = nil;
	if( !folderpath )
		appPath = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:executablepath length:strlen(executablepath)];
	else
		appPath = [host installationPath];
	[[NSWorkspace sharedWorkspace] openFile: appPath];
	if( folderpath )
	{
		NSError*		theError = nil;
    	if( ![SUPlainInstaller _removeFileAtPath: [SUInstaller updateFolder] error: &theError] )
			SULog( @"Couldn't remove update folder: %@.", theError );
	}
#if MAC_OS_X_VERSION_MIN_REQUIRED <= MAC_OS_X_VERSION_10_4
    [[NSFileManager defaultManager] removeFileAtPath: selfPath handler: nil];
#else
	[[NSFileManager defaultManager] removeItemAtPath: selfPath error: NULL];
#endif
	exit(EXIT_SUCCESS);
}


- (void) install
{
	NSBundle			*theBundle = [NSBundle bundleWithPath: [[NSFileManager defaultManager] stringWithFileSystemRepresentation: executablepath length:strlen(executablepath)]];
	host = [[SUHost alloc] initWithBundle: theBundle];
	
	SUStatusController*	statusCtl = [[SUStatusController alloc] initWithHost: host];	// We quit anyway after we've installed, so leak this for now.
	[statusCtl setButtonTitle: SULocalizedString(@"Cancel Update",@"") target: nil action: Nil isDefault: NO];
	[statusCtl beginActionWithTitle: SULocalizedString(@"Installing update...",@"")
					maxProgressValue: 0 statusText: @""];
	[statusCtl showWindow: self];
	
	[SUInstaller installFromUpdateFolder: [[NSFileManager defaultManager] stringWithFileSystemRepresentation: folderpath length: strlen(folderpath)]
					overHost: host
					delegate: self synchronously: NO
					versionComparator: [SUStandardVersionComparator defaultComparator]];
}

- (void) installerFinishedForHost:(SUHost *)aHost
{
	[self relaunch];
}

- (void) installerForHost:(SUHost *)host failedWithError:(NSError *)error
{
	NSRunAlertPanel( @"", @"%@", @"OK", @"", @"", [error localizedDescription] );
	exit(EXIT_FAILURE);
}

@end

int main (int argc, const char * argv[])
{
	if( argc < 3 || argc > 4 )
		return EXIT_FAILURE;
	
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	//ProcessSerialNumber		psn = { 0, kCurrentProcess };
	//TransformProcessType( &psn, kProcessTransformToForegroundApplication );
	[[NSApplication sharedApplication] activateIgnoringOtherApps: YES];
		
	#if 0	// Cmdline tool
	NSString*	selfPath = nil;
	if( argv[0][0] == '/' )
		selfPath = [[NSFileManager defaultManager] stringWithFileSystemRepresentation: argv[0] length: strlen(argv[0])];
	else
	{
		selfPath = [[NSFileManager defaultManager] currentDirectoryPath];
		selfPath = [selfPath stringByAppendingPathComponent: [[NSFileManager defaultManager] stringWithFileSystemRepresentation: argv[0] length: strlen(argv[0])]];
	}
	#else
	NSString*	selfPath = [[NSBundle mainBundle] bundlePath];
	#endif
	
	[NSApplication sharedApplication];
	[[[TerminationListener alloc] initWithExecutablePath: (argc > 1) ? argv[1] : NULL
										parentProcessId: (argc > 2) ? atoi(argv[2]) : 0
										folderPath: (argc > 3) ? argv[3] : NULL
										selfPath: selfPath] autorelease];
	[[NSApplication sharedApplication] run];
	
	[pool drain];
	
	return EXIT_SUCCESS;
}
