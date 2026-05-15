#ifndef FANCY_CAT_FZWATCH_CORESERVICES_SHIM_H
#define FANCY_CAT_FZWATCH_CORESERVICES_SHIM_H

// Minimal CoreFoundation + FSEvents shim shadowing the SDK umbrella so
// `@cInclude("CoreServices/CoreServices.h")` in upstream fzwatch can translate
// under Zig 0.16's Aro frontend. Aro cannot parse the real umbrella (it pulls
// in Metadata/MDItem with Objective-C blocks and xpc.h with nullability on
// `uuid_t`). Declarations here are minimal — only the symbols fzwatch's
// `src/watchers/macos.zig` references — and the real implementations come from
// the CoreServices framework at link time.

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned char Boolean;
typedef long CFIndex;
typedef double CFTimeInterval;
typedef uint32_t CFStringEncoding;

typedef const struct __CFAllocator *CFAllocatorRef;
typedef const void *CFTypeRef;
typedef const struct __CFString *CFStringRef;
typedef const struct __CFArray *CFArrayRef;
typedef struct __CFRunLoop *CFRunLoopRef;
typedef CFStringRef CFRunLoopMode;
typedef CFIndex CFComparisonResult;

typedef struct {
    CFIndex version;
    const void *(*retain)(CFAllocatorRef allocator, const void *value);
    void (*release)(CFAllocatorRef allocator, const void *value);
    CFStringRef (*copyDescription)(const void *value);
    Boolean (*equal)(const void *value1, const void *value2);
} CFArrayCallBacks;

#define kCFStringEncodingUTF8 ((CFStringEncoding)0x08000100)

extern const CFArrayCallBacks kCFTypeArrayCallBacks;
extern const CFStringRef kCFRunLoopDefaultMode;

CFStringRef CFStringCreateWithBytes(CFAllocatorRef alloc, const uint8_t *bytes,
                                    CFIndex numBytes, CFStringEncoding encoding,
                                    Boolean isExternalRepresentation);
void CFRelease(CFTypeRef cf);
CFComparisonResult CFStringCompare(CFStringRef theString1, CFStringRef theString2,
                                   CFIndex compareOptions);
CFArrayRef CFArrayCreate(CFAllocatorRef allocator, const void **values,
                         CFIndex numValues, const CFArrayCallBacks *callBacks);
CFRunLoopRef CFRunLoopGetCurrent(void);
int32_t CFRunLoopRunInMode(CFRunLoopMode mode, CFTimeInterval seconds,
                           Boolean returnAfterSourceHandled);

typedef struct __FSEventStream *FSEventStreamRef;
typedef const struct __FSEventStream *ConstFSEventStreamRef;
typedef uint64_t FSEventStreamEventId;
typedef uint32_t FSEventStreamEventFlags;
typedef uint32_t FSEventStreamCreateFlags;

#define kFSEventStreamEventIdSinceNow      ((FSEventStreamEventId)0xFFFFFFFFFFFFFFFFULL)
#define kFSEventStreamCreateFlagFileEvents ((FSEventStreamCreateFlags)0x00000010)
#define kFSEventStreamEventFlagItemModified ((FSEventStreamEventFlags)0x00001000)

typedef const void *(*FSEventStreamRetainCallBack)(const void *info);
typedef void (*FSEventStreamReleaseCallBack)(const void *info);
typedef CFStringRef (*FSEventStreamCopyDescriptionCallBack)(const void *info);

typedef struct FSEventStreamContext {
    CFIndex version;
    void *info;
    FSEventStreamRetainCallBack retain;
    FSEventStreamReleaseCallBack release;
    FSEventStreamCopyDescriptionCallBack copyDescription;
} FSEventStreamContext;

typedef void (*FSEventStreamCallback)(
    ConstFSEventStreamRef streamRef,
    void *clientCallBackInfo,
    size_t numEvents,
    void *eventPaths,
    const FSEventStreamEventFlags eventFlags[],
    const FSEventStreamEventId eventIds[]);

FSEventStreamRef FSEventStreamCreate(CFAllocatorRef allocator,
                                     FSEventStreamCallback callback,
                                     FSEventStreamContext *context,
                                     CFArrayRef pathsToWatch,
                                     FSEventStreamEventId sinceWhen,
                                     CFTimeInterval latency,
                                     FSEventStreamCreateFlags flags);
void FSEventStreamScheduleWithRunLoop(FSEventStreamRef streamRef,
                                      CFRunLoopRef runLoop,
                                      CFStringRef runLoopMode);
Boolean FSEventStreamStart(FSEventStreamRef streamRef);
void FSEventStreamStop(FSEventStreamRef streamRef);
void FSEventStreamInvalidate(FSEventStreamRef streamRef);
void FSEventStreamRelease(FSEventStreamRef streamRef);

#ifdef __cplusplus
}
#endif

#endif
