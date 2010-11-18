/*
 * Copyright 2007-2010 The OpenRA Developers (see AUTHORS)
 * This file is part of OpenRA, which is free software. It is made 
 * available to you under the terms of the GNU General Public License
 * as published by the Free Software Foundation. For more information,
 * see LICENSE.
 */

#import "GameInstall.h"
#import "Mod.h"

@implementation GameInstall
@synthesize gameURL;

-(id)initWithURL:(NSURL *)url
{
	self = [super init];
	if (self != nil)
	{
		gameURL = [url retain];
		downloadTasks = [[NSMutableDictionary alloc] init];
	}
	return self;
}

- (void)dealloc
{
	[gameURL release]; gameURL = nil;
	[downloadTasks release]; downloadTasks = nil;
	[super dealloc];
}

- (NSArray *)installedMods
{
	id raw = [self runUtilityQuery:@"-l"];
	id mods = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	return [mods componentsSeparatedByString:@"\n"];
}

- (NSDictionary *)infoForMods:(NSArray *)mods
{
	id query = [NSString stringWithFormat:@"-i=%@",[mods componentsJoinedByString:@","]];
	NSArray *lines = [[self runUtilityQuery:query] componentsSeparatedByString:@"\n"];
	
	NSMutableDictionary *ret = [NSMutableDictionary dictionary];
	NSMutableDictionary *fields = nil;
	NSString *current = nil;
	for (id l in lines)
	{
		id line = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (line == nil || [line length] == 0)
			continue;
		
		id kv = [line componentsSeparatedByString:@":"];
		if ([kv count] < 2)
			continue;
		
		id key = [kv objectAtIndex:0];
		id value = [kv objectAtIndex:1];
		
		if ([key isEqualToString:@"Error"])
		{	
			NSLog(@"Error: %@",value);
			continue;
		}
		
		if ([key isEqualToString:@"Mod"])
		{
			// Commit prev mod
			if (current != nil)
			{	
				id url = [gameURL URLByAppendingPathComponent:[NSString stringWithFormat:@"mods/%@",current]];
				[ret setObject:[Mod modWithId:current fields:fields baseURL:url] forKey:current];
			}
			NSLog(@"Parsing mod %@",value);
			current = value;
			fields = [NSMutableDictionary dictionary];			
		}
		
		if (fields != nil)
			[fields setObject:[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
					   forKey:key];
	}
	if (current != nil)
	{	
		id url = [gameURL URLByAppendingPathComponent:[NSString stringWithFormat:@"mods/%@",current]];
		[ret setObject:[Mod modWithId:current fields:fields baseURL:url] forKey:current];
	}
	
	return ret;
}

-(void)launchMod:(NSString *)mod
{
	// Use LaunchServices because neither NSTask or NSWorkspace support Info.plist _and_ arguments pre-10.6
	NSString *path = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"OpenRA.app/Contents/MacOS/OpenRA"];
	
	// First argument is the directory to run in
	// Second...Nth arguments are passed to OpenRA.Game.exe
	// Launcher wrapper sets mono --debug, gl renderer and support dir.
	NSArray *args = [NSArray arrayWithObjects:[gameURL absoluteString],
						[NSString stringWithFormat:@"Game.Mods=%@",mod],
					nil];

	FSRef appRef;
	CFURLGetFSRef((CFURLRef)[NSURL URLWithString:path], &appRef);

	// Set the launch parameters
	LSApplicationParameters params;
	params.version = 0;
	params.flags = kLSLaunchDefaults;
	params.application = &appRef;
	params.asyncLaunchRefCon = NULL;
	params.environment = NULL; // CFDictionaryRef of environment variables; could be useful
	params.argv = (CFArrayRef)args;
	params.initialEvent = NULL;

	ProcessSerialNumber psn;
	OSStatus err = LSOpenApplication(&params, &psn);

	// Bring the game window to the front
	if (err == noErr)
		SetFrontProcess(&psn);
}

- (NSString *)runUtilityQuery:(NSString *)arg
{
	NSPipe *outPipe = [NSPipe pipe];
    NSMutableArray *taskArgs = [NSMutableArray arrayWithObject:@"OpenRA.Utility.exe"];
	[taskArgs addObject:arg];
	
	NSTask *task = [[NSTask alloc] init];
    [task setCurrentDirectoryPath:[gameURL absoluteString]];
    [task setLaunchPath:@"/Library/Frameworks/Mono.framework/Commands/mono"];
    [task setArguments:taskArgs];
	[task setStandardOutput:outPipe];
	[task setStandardError:[task standardOutput]];
    [task launch];
	NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
	[task waitUntilExit];
    [task release];
	
	return [[[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding] autorelease];
}


- (BOOL)downloadUrl:(NSString *)url toPath:(NSString *)filename withId:(NSString *)key
{
	NSLog(@"Starting download...");
	if ([downloadTasks objectForKey:key] != nil)
	{
		NSLog(@"Error: a download is already in progress for %@",key);
		return NO;
	}
	
	NSTask *task = [[[NSTask alloc] init] autorelease];
	NSPipe *pipe = [NSPipe pipe];
	
    NSMutableArray *taskArgs = [NSMutableArray arrayWithObject:@"OpenRA.Utility.exe"];
	NSString *arg = [NSString stringWithFormat:@"--download-url=%@,%@",url,filename];
	[taskArgs addObject:arg];
	
    [task setCurrentDirectoryPath:[gameURL absoluteString]];
    [task setLaunchPath:@"/Library/Frameworks/Mono.framework/Commands/mono"];
    [task setArguments:taskArgs];
	[task setStandardOutput:pipe];
	
	NSFileHandle *readHandle = [pipe fileHandleForReading];
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:self
		   selector:@selector(utilityResponded:)
			   name:NSFileHandleReadCompletionNotification
			 object:readHandle];
	[nc addObserver:self
		   selector:@selector(utilityTerminated:)
			   name:NSTaskDidTerminateNotification
			 object:task];
    [task launch];
	[readHandle readInBackgroundAndNotify];
		
	[downloadTasks setObject:task forKey:key];
	return YES;
}

- (void)utilityResponded:(NSNotification *)n
{
	NSData *data = [[n userInfo] valueForKey:NSFileHandleNotificationDataItem];
	NSString *response = [[[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding] autorelease];
	NSLog(@"r: %@",response);

	// Keep reading
	if ([n object] != nil)
		[[n object] readInBackgroundAndNotify];
}

- (void)utilityTerminated:(NSNotification *)n
{
	id task = [n object];
	id pipe = [task standardOutput];
	
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc removeObserver:self name:NSFileHandleReadCompletionNotification object:[pipe fileHandleForReading]];
	[nc removeObserver:self name:NSTaskDidTerminateNotification object:task];
}

- (void)cancelDownload:(NSString *)key
{
	id task = [downloadTasks objectForKey:key];
	if (task == nil)
		return;
	
	[task interrupt];
}
@end
