/* Lightweight native macOS system probe for notrecall compat/run.
 * Subcommands:
 *   display-scale    Prints "2" for Retina main display, "1" for 1x external monitor.
 *   display-default  Prints Recall's default Overwatch resolution and refresh rate
 *                    ("<width> <height> <refresh>", e.g. "1920 1200 120" or "1920 1080 144").
 *   gpu-name         Prints the default Metal GPU name (e.g. "Apple M3 Pro").
 *   bt-voice-uid     Prints the built-in microphone CoreAudio UID when the default
 *                    input is a Bluetooth headset and the MacBook lid is open;
 *                    prints nothing otherwise.
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>

static UInt32 audioValue(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = {
        selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 value = 0, size = sizeof(value);
    return AudioObjectGetPropertyData(object, &address, 0, NULL, &size, &value) == noErr ? value : 0;
}

static BOOL lidClosed(void) {
    io_service_t domain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!domain) return NO;
    CFTypeRef value = IORegistryEntryCreateCFProperty(domain, CFSTR("AppleClamshellState"), kCFAllocatorDefault, 0);
    IOObjectRelease(domain);
    BOOL closed = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
    if (value) CFRelease(value);
    return closed;
}

static NSString *builtInMicUIDForBluetoothHeadset(void) {
    UInt32 input = audioValue(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultInputDevice);
    UInt32 transport = input ? audioValue(input, kAudioDevicePropertyTransportType) : 0;
    if (transport != kAudioDeviceTransportTypeBluetooth &&
        transport != kAudioDeviceTransportTypeBluetoothLE) {
        return nil;
    }
    if (lidClosed()) return nil;

    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr || size == 0) {
        return nil;
    }
    NSMutableData *devices = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices.mutableBytes) != noErr) {
        return nil;
    }
    const AudioObjectID *ids = devices.bytes;
    for (NSUInteger i = 0; i < size / sizeof(AudioObjectID); i++) {
        if (audioValue(ids[i], kAudioDevicePropertyTransportType) != kAudioDeviceTransportTypeBuiltIn ||
            !audioValue(ids[i], kAudioDevicePropertyDeviceIsAlive)) {
            continue;
        }
        AudioObjectPropertyAddress streams = {
            kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain
        };
        UInt32 streamSize = 0;
        if (AudioObjectGetPropertyDataSize(ids[i], &streams, 0, NULL, &streamSize) != noErr || !streamSize) {
            continue;
        }
        AudioObjectPropertyAddress uidAddress = {
            kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
        };
        CFStringRef uid = NULL;
        UInt32 uidSize = sizeof(uid);
        if (AudioObjectGetPropertyData(ids[i], &uidAddress, 0, NULL, &uidSize, &uid) == noErr && uid) {
            return CFBridgingRelease(uid);
        }
    }
    return nil;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: notrecall-sysinfo <display-scale|display-default|gpu-name|bt-voice-uid>\n");
            return 2;
        }
        NSString *cmd = @(argv[1]);
        if ([cmd isEqualToString:@"display-scale"]) {
            CGDisplayModeRef mode = CGDisplayCopyDisplayMode(CGMainDisplayID());
            int scale = 2;
            if (mode) {
                scale = (CGDisplayModeGetPixelWidth(mode) > CGDisplayModeGetWidth(mode)) ? 2 : 1;
                CGDisplayModeRelease(mode);
            }
            printf("%d\n", scale);
            return 0;
        }
        if ([cmd isEqualToString:@"display-default"]) {
            int width = 1920, height = 1200, refresh = 120;
            CGDisplayModeRef mode = CGDisplayCopyDisplayMode(CGMainDisplayID());
            if (mode) {
                size_t mw = CGDisplayModeGetWidth(mode);
                size_t mh = CGDisplayModeGetHeight(mode);
                if (mh > 0 && ((double)mw / (double)mh) >= 1.69) {
                    height = 1080;
                }
                long r = lround(CGDisplayModeGetRefreshRate(mode));
                if (r >= 24 && r <= 999) {
                    refresh = (int)r;
                }
                CGDisplayModeRelease(mode);
            }
            printf("%d %d %d\n", width, height, refresh);
            return 0;
        }
        if ([cmd isEqualToString:@"gpu-name"]) {
            id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
            if (dev.name.length) {
                printf("%s\n", dev.name.UTF8String);
            }
            return 0;
        }
        if ([cmd isEqualToString:@"bt-voice-uid"]) {
            NSString *uid = builtInMicUIDForBluetoothHeadset();
            if (uid.length) {
                printf("%s\n", uid.UTF8String);
            }
            return 0;
        }
        fprintf(stderr, "unknown subcommand: %s\n", argv[1]);
        return 2;
    }
}
