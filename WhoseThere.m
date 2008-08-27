#import <Foundation/Foundation.h>
#import <netinet/in.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netdb.h>

static NSString *PeernameFromSocket (int sockfd) {
    NSString *retval = nil;
    struct sockaddr_in addr;
    socklen_t size = sizeof(addr);
    if (0 == getpeername(sockfd, (struct sockaddr *)&addr, &size)) {
        struct hostent *entry = gethostbyaddr(&addr, size, AF_INET);
        if (!entry) {
            char buf[INET6_ADDRSTRLEN];
            retval = [NSString stringWithFormat:@"%s", inet_ntop(addr.sin_family, &(addr.sin_addr), buf, sizeof(buf))];
        } else {
            retval = [NSString stringWithFormat:@"%s", entry->h_name];
        }
    }
    return retval;
}

@interface BPConnection : NSObject {
    NSString *_peername;
    NSInputStream *_iStream;
    NSOutputStream *_oStream;
}
@end
@implementation BPConnection
- (id)initWithSockFD:(int)sockfd {
    if ((self = [super init])) {
        _peername = [PeernameFromSocket(sockfd) retain];
        CFStreamCreatePairWithSocket(kCFAllocatorDefault, sockfd, (CFReadStreamRef *)&_iStream, (CFWriteStreamRef *)&_oStream);        
        [_iStream setDelegate:self];
        [_oStream setDelegate:self];
        [_iStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        [_oStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        [_iStream open];
        [_oStream open];
    }
    return self;
}

- (void)dealloc {
    [_peername release];
    [_iStream release];
    [_oStream release];
    [super dealloc];
}

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
    NSLog(@"Got stream event %d", eventCode);
    if (eventCode == NSStreamEventErrorOccurred) {
        NSLog(@"Got Error %@", [aStream streamError]);
    } else if (eventCode == NSStreamEventHasBytesAvailable && aStream == _iStream) {
        uint8_t buf[1024];
        int bytesRead = [_iStream read:buf maxLength:sizeof(buf)];
        if (bytesRead > 0) {
            NSString *aString = [[NSString alloc] initWithBytes:buf length:bytesRead encoding:NSUTF8StringEncoding];
            NSLog(@"%@ says %@", _peername, aString);
            [aString release];
        } else {
            NSLog(@"Couldn't read data");
        }
    }
}
@end

@interface BPServer : NSObject {
    NSNetService *_netService;
    CFSocketRef _socket;
    NSMutableArray *_connections;
}
@end
@implementation BPServer

- (void) _publishNetServiceOnPort:(uint16_t)port {
    NSAssert(_netService == nil, @"Can only publish once");
    _netService = [[NSNetService alloc] initWithDomain:@"" type:@"_shiz._tcp." name:@"TheShizzle" port:port];
    [_netService setDelegate:self];
    [_netService publish];
}

- (void) _addConnectionWithSockFD:(int)sockfd {
    if (!_connections) _connections = [[NSMutableArray alloc] init];
    BPConnection *connection = [[BPConnection alloc] initWithSockFD:sockfd];
    [_connections addObject:connection];
    [connection release];
}

static void ServerSocketCallback (CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
    NSLog(@"Got socket callback %d", type);
    if (type == kCFSocketAcceptCallBack) {
        [(BPServer *)info _addConnectionWithSockFD:*(int *)data];
    }
}

- (id) init {
    if ((self = [super init])) {
        NSLog(@"Creating socket");
        CFSocketContext context = {0, self, NULL, NULL, NULL};
        _socket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP, kCFSocketAcceptCallBack, ServerSocketCallback, &context);
        
        struct sockaddr_in addr = { 0 };
        addr.sin_len = sizeof(addr);
        addr.sin_family = AF_INET;
        addr.sin_port = htons(0);
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        CFDataRef addrData = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, (UInt8 *)&addr, sizeof(addr), kCFAllocatorNull);
        if (kCFSocketSuccess != CFSocketSetAddress(_socket, addrData)) {
            NSLog(@"Couldn't bind socket");
        }
        CFRelease(addrData);
        
        CFRunLoopSourceRef rlSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _socket, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rlSource, kCFRunLoopCommonModes);
        CFRelease(rlSource);
        
        NSData *address = (NSData *)CFSocketCopyAddress(_socket);
        const struct sockaddr_in *addrWithPort = [address bytes];
        [self _publishNetServiceOnPort:ntohs(addrWithPort->sin_port)];
        [address release];
    }
    return self;
}
- (void)dealloc {
    if (_socket) {
        CFSocketInvalidate(_socket);
        CFRelease(_socket);
    }
    
    [_netService release];
    [_connections release];
    [super dealloc];
}

#pragma mark -
#pragma mark NSNetService Delegate Methods

- (void)netServiceDidPublish:(NSNetService *)sender {
    NSLog(@"Service published");
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary *)errorDict {
    NSLog(@"Service did not publish %@", errorDict);
}
@end



@interface BPClient : NSObject {
    NSNetServiceBrowser *_browser;
    NSInputStream *_iStream;
    NSOutputStream *_oStream;
}
@end
@implementation BPClient
- (id) init {
    if ((self = [super init])) {
        _browser = [[NSNetServiceBrowser alloc] init];
        [_browser setDelegate:self];
        [_browser searchForServicesOfType:@"_shiz._tcp." inDomain:@""];
    }
    return self;
}

- (void)dealloc {
    [_browser release];
    [_iStream release];
    [_oStream release];
    [super dealloc];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)netServiceBrowser didFindService:(NSNetService *)netService moreComing:(BOOL)moreServicesComing {
    NSLog(@"%s", _cmd);
    if (_iStream || _oStream) {
        NSLog(@"Already connected to a service");
        return;
    }
    [netService retain];  // released in netServiceDidResolveAddress:
    [netService setDelegate:self];
    [netService resolve];
}

- (void)netServiceDidResolveAddress:(NSNetService *)sender {
    NSLog(@"%s %@", _cmd, [sender hostName]);
    
    char buf[256];
    for (NSData *addrData in [sender addresses]) {
        const struct sockaddr_in *addr = [addrData bytes];
        NSLog(@"%s", inet_ntop(addr->sin_family, (void *)&addr->sin_addr, buf, sizeof(buf)));
    }
    
    if ([sender addresses]) {
        [sender getInputStream:&_iStream outputStream:&_oStream];
        
        [_iStream setDelegate:self];
        [_oStream setDelegate:self];
        [_iStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        [_oStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        [_iStream open];
        [_oStream open];
    } else {
        NSLog(@"No addresses in NSNetService");
    }
    [sender release];
}
- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary *)errorDict {
    NSLog(@"%s Error: %@", __func__, errorDict);
    [sender release];
}

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
    if (eventCode == NSStreamEventErrorOccurred) {
        NSLog(@"Got Error %@", [aStream streamError]);
    } else if (eventCode == NSStreamEventOpenCompleted && aStream == _oStream) {
        NSLog(@"Output stream opened");
    } else if (eventCode == NSStreamEventHasSpaceAvailable && aStream == _oStream) {
        static BOOL wroteOnce = NO;
        if (!wroteOnce) {
            NSString *writeString = @"yo mama";
            NSInteger bytesWritten = [_oStream write:(uint8_t *)[writeString UTF8String] maxLength:[writeString length]];
            NSLog(@"Wrote %d byte%@", bytesWritten, bytesWritten == 1 ? @"" : @"s");
            wroteOnce = YES;
        }
    }
}
@end

static void Server () {
    NSLog(@"Running as server");
    BPServer *server = [[BPServer alloc] init];
    [[NSRunLoop currentRunLoop] run];
    [server release];
}

static void Client () {
    NSLog(@"Running as client");
    BPClient *client = [[BPClient alloc] init];
    [[NSRunLoop currentRunLoop] run];
    [client release];
}

int main (int argc, const char * argv[]) {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    
    if (argc > 1 && strcmp("--server", argv[1]) == 0) {
        Server();
    } else {
        Client();
    }
    
    [pool drain];
    return 0;
}
