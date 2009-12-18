/*
 #  SOCKS - SOCKS Proxy for iPhone
 #  Copyright (C) 2009 Ehud Ben-Reuven
 #  udi@benreuven.com
 #
 # This program is free software; you can redistribute it and/or
 # modify it under the terms of the GNU General Public License
 # as published by the Free Software Foundation version 2.
 #
 # This program is distributed in the hope that it will be useful,
 # but WITHOUT ANY WARRANTY; without even the implied warranty of
 # MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 # GNU General Public License for more details.
 #
 # You should have received a copy of the GNU General Public License
 # along with this program; if not, write to the Free Software
 # Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,USA.
 */

#import "SocksProxyController.h"

#import "AppDelegate.h"

#include <CFNetwork/CFNetwork.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include "myipaddr.h"

@interface SocksProxyController ()

// Properties that don't need to be seen by the outside world.

@property (nonatomic, readonly) BOOL                isStarted;
@property (nonatomic, retain)   NSNetService *      netService;
@property (nonatomic, assign)   CFSocketRef         listeningSocket;
@property (nonatomic, assign)   NSInteger			nConnections;
@property (nonatomic, readonly) SocksProxy **       sendreceiveStream;

// Forward declarations

- (void)_stopServer:(NSString *)reason;

@end

@implementation SocksProxyController
@synthesize nConnections  = _nConnections;
// Because sendreceiveStream is declared as an array, you have to use a custom getter.  
// A synthesised getter doesn't compile.

- (SocksProxy **)sendreceiveStream
{
    return self->_sendreceiveStream;
}

#pragma mark * Status management

// These methods are used by the core transfer code to update the UI.

- (void)_serverDidStartOnPort:(int)port
{
    assert( (port > 0) && (port < 65536) );
    //self.statusLabel.text = [NSString stringWithFormat:@"%d.%d.%d.%d %d", (ipaddr>>24),0xff&(ipaddr>>16),0xff&(ipaddr>>8),0xff&ipaddr, port];
    self.statusLabel.text = @"Started";
    self.portLabel.text = [NSString stringWithFormat:@"%d", port];
	self.addressLabel.text =[NSString stringWithCString:myipaddr() encoding:[NSString defaultCStringEncoding]];

    [self.startOrStopButton setTitle:@"Stop" forState:UIControlStateNormal];
    self.tabBarItem.image = [UIImage imageNamed:@"receiveserverOn.png"];
}

- (void)_serverDidStopWithReason:(NSString *)reason
{
    if (reason == nil) {
        reason = @"Stopped";
    }
	self.addressLabel.text=@"";
	self.portLabel.text=@"";
    self.statusLabel.text = reason;
    [self.startOrStopButton setTitle:@"Start" forState:UIControlStateNormal];
    self.tabBarItem.image = [UIImage imageNamed:@"receiveserverOff.png"];
#if __DEBUG__
	NSLog(@"Server Stopped: %@",reason);
#endif
}

- (void)_sendreceiveDidStart
{
    self.statusLabel.text = @"Receiving";
    [self.activityIndicator startAnimating];
    [[AppDelegate sharedAppDelegate] didStartNetworking];
}

- (void)_updateStatus:(NSString *)statusString
{
    assert(statusString != nil);
    self.statusLabel.text = statusString;
#if __DEBUG__
	NSLog(@"Status: %@",statusString);
#endif
}

- (void)_sendreceiveDidStopWithStatus:(NSString *)statusString
{
    if (statusString == nil) {
        statusString = @"Receive succeeded";
    }
    self.statusLabel.text = statusString;
    [self.activityIndicator stopAnimating];
    [[AppDelegate sharedAppDelegate] didStopNetworking];
	
	int countOpen=0;
	int i;
	for(i=0;i<self.nConnections;i++)
		if ( ! self.sendreceiveStream[i].isSendingReceiving )
			countOpen++;
#if __DEBUG__
	NSLog(@"Connection ended %d %d: %@",countOpen,self.nConnections,statusString);
#endif
}

#pragma mark * Core transfer code

// This is the code that actually does the networking.

@synthesize netService      = _netService;
@synthesize listeningSocket = _listeningSocket;

- (BOOL)isStarted
{
    return (self.netService != nil);
}

// Have to write our own setter for listeningSocket because CF gets grumpy 
// if you message NULL.

- (void)setListeningSocket:(CFSocketRef)newValue
{
    if (newValue != self->_listeningSocket) {
        if (self->_listeningSocket != NULL) {
            CFRelease(self->_listeningSocket);
        }
        self->_listeningSocket = newValue;
        if (self->_listeningSocket != NULL) {
            CFRetain(self->_listeningSocket);
        }
    }
}

- (void)_acceptConnection:(int)fd
{
	SocksProxy *proxy=nil;
	int i;
	for(i=0;i<self.nConnections;i++)
		if ( ! self.sendreceiveStream[i].isSendingReceiving ) {
			proxy = self.sendreceiveStream[i];
			break;
		}
	
	if(!proxy) {
		if(i>NCONNECTIONS) {
			close(fd);
			return;
		}
		proxy = [[SocksProxy alloc] init];
		self.sendreceiveStream[i] = proxy;
		self.sendreceiveStream[i].delegate = self;
		self.nConnections++;
	}
	int countOpen=0;
	for(i=0;i<self.nConnections;i++)
		if ( ! self.sendreceiveStream[i].isSendingReceiving )
			countOpen++;
#if __DEBUG__
	NSLog(@"Accept connection %d %d",countOpen,self.nConnections);
#endif	
	[proxy startSendReceive:fd];
}

static void AcceptCallback(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
    // Called by CFSocket when someone connects to our listening socket.  
    // This implementation just bounces the request up to Objective-C.
{
    SocksProxyController *  obj;
    
    #pragma unused(type)
    assert(type == kCFSocketAcceptCallBack);
    #pragma unused(address)
    // assert(address == NULL);
    assert(data != NULL);
    
    obj = (SocksProxyController *) info;
    assert(obj != nil);

    #pragma unused(s)
    assert(s == obj->_listeningSocket);
    
    [obj _acceptConnection:*(int *)data];
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary *)errorDict
    // A NSNetService delegate callback that's called if our Bonjour registration 
    // fails.  We respond by shutting down the server.
    //
    // This is another of the big simplifying assumptions in this sample. 
    // A real server would use the real name of the device for registrations, 
    // and handle automatically renaming the service on conflicts.  A real 
    // client would allow the user to browse for services.  To simplify things 
    // we just hard-wire the service name in the client and, in the server, fail 
    // if there's a service name conflict.
{
    #pragma unused(sender)
    assert(sender == self.netService);
    #pragma unused(errorDict)
    
    [self _stopServer:@"Registration failed"];
}

- (void)_startServer
{
    BOOL        success;
    int         err;
    int         fd;
    int         junk;
    struct sockaddr_in addr;
    int         port;
	
	self.nConnections=0;
    // Create a listening socket and use CFSocket to integrate it into our 
    // runloop.  We bind to port 0, which causes the kernel to give us 
    // any free port, then use getsockname to find out what port number we 
    // actually got.

    port = 0;
    
    fd = socket(AF_INET, SOCK_STREAM, 0);
    success = (fd != -1);
    
    if (success) {
        memset(&addr, 0, sizeof(addr));
        addr.sin_len    = sizeof(addr);
        addr.sin_family = AF_INET;
        addr.sin_port   = htons(port);
        addr.sin_addr.s_addr = INADDR_ANY;
        err = bind(fd, (const struct sockaddr *) &addr, sizeof(addr));
        success = (err == 0);
    }
    if (success) {
        err = listen(fd, 5);
        success = (err == 0);
    }
    if (success) {
        socklen_t   addrLen;

        addrLen = sizeof(addr);
        err = getsockname(fd, (struct sockaddr *) &addr, &addrLen);
        success = (err == 0);
        
        if (success) {
            assert(addrLen == sizeof(addr));
            port = ntohs(addr.sin_port);
        }
    }
    if (success) {
        CFSocketContext context = { 0, self, NULL, NULL, NULL };
        
        self.listeningSocket = CFSocketCreateWithNative(
            NULL, 
            fd, 
            kCFSocketAcceptCallBack, 
            AcceptCallback, 
            &context
        );
        success = (self.listeningSocket != NULL);
        
        if (success) {
            CFRunLoopSourceRef  rls;
            
            CFRelease(self.listeningSocket);        // to balance the create

            fd = -1;        // listeningSocket is now responsible for closing fd

            rls = CFSocketCreateRunLoopSource(NULL, self.listeningSocket, 0);
            assert(rls != NULL);
            
            CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, kCFRunLoopDefaultMode);
            
            CFRelease(rls);
        }
    }

    // Now register our service with Bonjour.  See the comments in -netService:didNotPublish: 
    // for more info about this simplifying assumption.

    if (success) {
        //self.netService = [[[NSNetService alloc] initWithDomain:@"local." type:@"_x-SNSUpload._tcp." name:@"Test" port:port] autorelease];
        self.netService = [[[NSNetService alloc] initWithDomain:@"" type:@"_socks5._tcp." name:@"Test" port:port] autorelease];
        success = (self.netService != nil);
    }
    if (success) {
        self.netService.delegate = self;
        
        [self.netService publishWithOptions:NSNetServiceNoAutoRename];
        
        // continues in -netServiceDidPublish: or -netService:didNotPublish: ...
    }
    
    // Clean up after failure.
    
    if ( success ) {
        assert(port != 0);
        [self _serverDidStartOnPort:port];
    } else {
        [self _stopServer:@"Start failed"];
        if (fd != -1) {
            junk = close(fd);
            assert(junk == 0);
        }
    }
}

- (void)_stopServer:(NSString *)reason
{
	int i;
	for (i=0; i<self.nConnections; i++) {
		if (self.sendreceiveStream[i].isSendingReceiving)
			[self.sendreceiveStream[i] stopSendReceiveWithStatus:@"Cancelled"];
    }
	
    if (self.netService != nil) {
        [self.netService stop];
        self.netService = nil;
    }
    if (self.listeningSocket != NULL) {
        CFSocketInvalidate(self.listeningSocket);
        self.listeningSocket = NULL;
    }
    [self _serverDidStopWithReason:reason];
}


#pragma mark * Actions

- (IBAction)startOrStopAction:(id)sender
{
    #pragma unused(sender)
    if (self.isStarted) {
        [self _stopServer:nil];
    } else {
        [self _startServer];
    }
}

#pragma mark * View controller boilerplate

@synthesize addressLabel       = _addressLabel;
@synthesize portLabel       = _portLabel;
@synthesize statusLabel       = _statusLabel;
@synthesize activityIndicator = _activityIndicator;
@synthesize startOrStopButton = _startOrStopButton;

- (void)viewDidLoad
{
    [super viewDidLoad];
    assert(self.statusLabel != nil);
    assert(self.activityIndicator != nil);
    assert(self.startOrStopButton != nil);
    
    self.activityIndicator.hidden = YES;
    self.statusLabel.text = @"Tap Start to start the server";
}

- (void)viewDidUnload
{
    [super viewDidUnload];
    self.statusLabel = nil;
    self.activityIndicator = nil;
    self.startOrStopButton = nil;
}

- (void)dealloc
{
    [self _stopServer:nil];
	int i;
	for(i=0;i<self.nConnections;i++)
		[self.sendreceiveStream[i] dealloc];
    
    [self->_statusLabel release];
    [self->_activityIndicator release];
    [self->_startOrStopButton release];

    [super dealloc];
}

@end