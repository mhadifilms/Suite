/**
 * @file src/platform/macos/vd_helper.m
 * @brief Helper process to create and hold a CGVirtualDisplay.
 *
 * Spawned by Sunshine to create virtual displays in a clean process context.
 * Usage: vd_helper <width> <height> <fps>
 * Outputs: displayID on stdout (or "0" on failure)
 * Stays alive holding the display until SIGTERM is received.
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <signal.h>
#include <unistd.h>

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (retain, nonatomic) NSArray *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) CGPoint whitePoint;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (retain, nonatomic) dispatch_queue_t queue;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

extern CGError SLSBeginDisplayConfiguration(CGDisplayConfigRef *);
extern CGError SLSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool);
extern CGError SLSConfigureDisplayOrigin(CGDisplayConfigRef, CGDirectDisplayID, int32_t, int32_t);
extern CGError SLSCompleteDisplayConfiguration(CGDisplayConfigRef, CGConfigureOption, uint32_t);

static CGVirtualDisplay *keepAlive = nil;
static CGVirtualDisplayDescriptor *keepDesc = nil;
static volatile sig_atomic_t shouldExit = 0;

static void handle_signal(int sig) {
  (void)sig;
  shouldExit = 1;
}

static BOOL checkDisplayInList(uint32_t targetID, uint32_t *outCount) {
  CGDirectDisplayID activeDisplays[32];
  uint32_t displayCount = 0;
  if (CGGetActiveDisplayList(32, activeDisplays, &displayCount) == kCGErrorSuccess) {
    if (outCount) *outCount = displayCount;
    for (uint32_t i = 0; i < displayCount; i++) {
      if (activeDisplays[i] == targetID) return YES;
    }
  }
  return NO;
}

static CGSize physicalSizeForResolution(int width, int height) {
  const double targetPPI = 163.0;
  const double maxDiagonalInches = 32.0;
  const double diagonalPixels = hypot((double)width, (double)height);
  const double diagonalInches = fmin(diagonalPixels / targetPPI, maxDiagonalInches);
  const double diagonalMM = diagonalInches * 25.4;

  return CGSizeMake(
    diagonalMM * ((double)width / diagonalPixels),
    diagonalMM * ((double)height / diagonalPixels)
  );
}

static void addMode(NSMutableArray *modes, int width, int height, int fps) {
  if (width <= 0 || height <= 0 || fps <= 0) {
    return;
  }

  CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int)width
                                                                    height:(unsigned int)height
                                                               refreshRate:(double)fps];
  if (mode) {
    [modes addObject:mode];
  }
}

static NSArray *modeListForResolution(int width, int height, int fps) {
  NSMutableArray *modes = [NSMutableArray array];
  const int widths[] = { width, width / 2, width / 4 };
  const int heights[] = { height, height / 2, height / 4 };

  for (size_t i = 0; i < 3; i++) {
    addMode(modes, widths[i], heights[i], fps);
    if (fps != 60) {
      addMode(modes, widths[i], heights[i], 60);
    }
  }

  return modes;
}

static void forceExtendMode(CGDirectDisplayID virtualID) {
  CGDirectDisplayID mainDisplay = CGMainDisplayID();

  CGDirectDisplayID mainMirrorTarget = CGDisplayMirrorsDisplay(mainDisplay);
  if (mainMirrorTarget == virtualID) {
    fprintf(stderr, "[vd_helper] Main display is mirroring us (%u), un-mirroring main\n", virtualID);
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      CGConfigureDisplayMirrorOfDisplay(config, mainMirrorTarget, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    }
  }

  if (CGDisplayIsInMirrorSet(virtualID)) {
    fprintf(stderr, "[vd_helper] Display %u is in mirror set, un-mirroring\n", virtualID);
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      CGConfigureDisplayMirrorOfDisplay(config, virtualID, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    }
  }

  CGDirectDisplayID virtualMirrorTarget = CGDisplayMirrorsDisplay(virtualID);
  if (virtualMirrorTarget != 0) {
    fprintf(stderr, "[vd_helper] Display %u mirrors %u, un-mirroring\n", virtualID, virtualMirrorTarget);
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      CGConfigureDisplayMirrorOfDisplay(config, virtualID, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    }
  }

  CGDisplayConfigRef config = NULL;
  CGBeginDisplayConfiguration(&config);
  if (config) {
    size_t mainWidth = CGDisplayPixelsWide(mainDisplay);
    CGConfigureDisplayOrigin(config, virtualID, (int32_t)mainWidth, 0);
    CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
  }

  CGDirectDisplayID newMain = CGMainDisplayID();
  if (newMain == virtualID && newMain != mainDisplay) {
    fprintf(stderr, "[vd_helper] Virtual display became main, restoring original main %u\n", mainDisplay);
    CGDisplayConfigRef restoreConfig = NULL;
    CGBeginDisplayConfiguration(&restoreConfig);
    if (restoreConfig) {
      CGConfigureDisplayOrigin(restoreConfig, mainDisplay, 0, 0);
      CGCompleteDisplayConfiguration(restoreConfig, kCGConfigureForAppOnly);
    }
  }
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 4) {
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    int width = atoi(argv[1]);
    int height = atoi(argv[2]);
    int fps = atoi(argv[3]);

    if (width <= 0 || height <= 0 || fps <= 0 || width > 7680 || height > 4320) {
      if (width > 7680 || height > 4320) {
        fprintf(stderr, "[vd_helper] Requested display %dx%d exceeds 7680x4320 maximum\n", width, height);
      }
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    if (!NSClassFromString(@"CGVirtualDisplay")) {
      fprintf(stderr, "[vd_helper] CGVirtualDisplay API not available\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);
    signal(SIGHUP, handle_signal);

    CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
    desc.name = @"Sunshine Virtual Display";
    desc.vendorID = 0xF0F0;
    desc.productID = 0x5678;
    desc.serialNum = arc4random();
    desc.maxPixelsWide = (unsigned int)width;
    desc.maxPixelsHigh = (unsigned int)height;
    desc.sizeInMillimeters = physicalSizeForResolution(width, height);
    desc.whitePoint = CGPointMake(0.3127, 0.3290);
    desc.redPrimary = CGPointMake(0.680, 0.320);
    desc.greenPrimary = CGPointMake(0.265, 0.690);
    desc.bluePrimary = CGPointMake(0.150, 0.060);
    [desc setDispatchQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)];
    desc.terminationHandler = ^(id s, id d) {
      fprintf(stderr, "[vd_helper] Virtual display terminated by system\n");
    };

    NSArray *displayModes = modeListForResolution(width, height, fps);
    if (displayModes.count == 0) {
      fprintf(stderr, "[vd_helper] Failed to create CGVirtualDisplayMode list\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = 1;
    settings.modes = displayModes;

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    if (!display) {
      fprintf(stderr, "[vd_helper] initWithDescriptor returned nil (trying background thread)\n");
      __block CGVirtualDisplay *bgDisplay = nil;
      dispatch_semaphore_t sem = dispatch_semaphore_create(0);
      dispatch_async(dispatch_get_global_queue(0, 0), ^{
        bgDisplay = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
        if (bgDisplay) [bgDisplay applySettings:settings];
        dispatch_semaphore_signal(sem);
      });
      dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC));
      display = bgDisplay;
    } else {
      [display applySettings:settings];
    }

    if (!display || display.displayID == 0) {
      fprintf(stderr, "[vd_helper] Failed to create virtual display\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    keepAlive = display;
    keepDesc = desc;
    uint32_t resultID = display.displayID;

    fprintf(stderr, "[vd_helper] Display %u created, activating...\n", resultID);

    CGDisplayConfigRef cgConfig = NULL;
    CGError err = SLSBeginDisplayConfiguration(&cgConfig);
    fprintf(stderr, "[vd_helper] SLSBeginDisplayConfiguration: %d\n", err);
    if (err == kCGErrorSuccess && cgConfig) {
      err = SLSConfigureDisplayEnabled(cgConfig, resultID, true);
      fprintf(stderr, "[vd_helper] SLSConfigureDisplayEnabled(%u, true): %d\n", resultID, err);
      CGDirectDisplayID mainDisplay = CGMainDisplayID();
      size_t mainWidth = CGDisplayPixelsWide(mainDisplay);
      SLSConfigureDisplayOrigin(cgConfig, resultID, (int32_t)mainWidth, 0);
      CGError completeErr = SLSCompleteDisplayConfiguration(cgConfig, kCGConfigureForSession, 0);
      fprintf(stderr, "[vd_helper] SLSCompleteDisplayConfiguration: %d\n", completeErr);
    }

    usleep(500000);

    if (CGDisplayIsInMirrorSet(resultID) || CGDisplayMirrorsDisplay(resultID) != 0) {
      fprintf(stderr, "[vd_helper] Mirror detected, forcing extend mode\n");
      forceExtendMode(resultID);
    }

    NSDictionary *opts = @{(NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(resultID, (CFDictionaryRef)opts);
    if (allModes) {
      CGDisplayModeRef nativeCGMode = NULL;
      CFIndex modeCount = CFArrayGetCount(allModes);
      for (CFIndex i = 0; i < modeCount; i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        size_t lw = CGDisplayModeGetWidth(m);
        size_t lh = CGDisplayModeGetHeight(m);
        size_t pw = CGDisplayModeGetPixelWidth(m);
        size_t ph = CGDisplayModeGetPixelHeight(m);
        if ((int)lw == width && (int)lh == height && pw == lw && ph == lh) {
          nativeCGMode = m;
          break;
        }
      }
      if (nativeCGMode) {
        CGError modeErr = CGDisplaySetDisplayMode(resultID, nativeCGMode, NULL);
        fprintf(stderr, "[vd_helper] Switched to native %dx%d (1x scale): %d\n", width, height, modeErr);
      } else {
        fprintf(stderr, "[vd_helper] Native %dx%d mode not found, staying at retina 2x\n", width, height);
      }
      CFRelease(allModes);
    }

    usleep(500000);

    uint32_t count = 0;
    BOOL found = checkDisplayInList(resultID, &count);
    if (!found) {
      fprintf(stderr, "[vd_helper] Display %u not found after first attempt, retrying...\n", resultID);
      sleep(1);
      fprintf(stderr, "[vd_helper] Mirror state (retry): inMirrorSet=%d, mirrorsDisplay=%u\n",
              CGDisplayIsInMirrorSet(resultID), CGDisplayMirrorsDisplay(resultID));
      forceExtendMode(resultID);
      usleep(500000);
      found = checkDisplayInList(resultID, &count);
    }

    fprintf(stderr, "[vd_helper] Display %u (%dx%d@%dHz) - %s in active list (%u total)\n",
            resultID, width, height, fps, found ? "FOUND" : "NOT found", count);

    CGDirectDisplayID activeDisplays[32];
    uint32_t dCount = 0;
    CGGetActiveDisplayList(32, activeDisplays, &dCount);
    for (uint32_t i = 0; i < dCount; i++) {
      fprintf(stderr, "[vd_helper]   active[%u] = %u (online=%d, active=%d, mirror=%u)\n",
              i, activeDisplays[i],
              CGDisplayIsOnline(activeDisplays[i]),
              CGDisplayIsActive(activeDisplays[i]),
              CGDisplayMirrorsDisplay(activeDisplays[i]));
    }
    fprintf(stderr, "[vd_helper]   ours[%u]: online=%d, active=%d, inMirror=%d, mirrors=%u\n",
            resultID,
            CGDisplayIsOnline(resultID),
            CGDisplayIsActive(resultID),
            CGDisplayIsInMirrorSet(resultID),
            CGDisplayMirrorsDisplay(resultID));

    if (!found) {
      fprintf(stderr, "[vd_helper] Display %u never became active; failing virtual display creation\n", resultID);
      keepAlive = nil;
      keepDesc = nil;
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    fprintf(stdout, "%u\n", resultID);
    fflush(stdout);

    while (!shouldExit) {
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
    }

    fprintf(stderr, "[vd_helper] Shutting down, releasing display %u\n", resultID);
    keepAlive = nil;
    keepDesc = nil;
  }
  return 0;
}
