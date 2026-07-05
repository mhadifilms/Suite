/**
 * @file src/platform/macos/sc_capture.m
 * @brief ScreenCaptureKit-based video capture implementation for macOS 12.3+.
 */
#import "sc_capture.h"

API_AVAILABLE(macos(12.3))
@implementation SCCapture

+ (BOOL)isAvailable {
  if (@available(macOS 12.3, *)) {
    return YES;
  }
  return NO;
}

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate {
  self = [super init];
  if (!self) {
    return nil;
  }

  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
  self.displayID = displayID;
  self.frameRate = frameRate;
  self.pixelFormat = kCVPixelFormatType_32BGRA;
  self.hdrDisplay = NO;
  self.loggedPixelFormat = NO;
  self.pixelFormatMismatch = NO;
  self.captureCursor = YES;

  if (mode) {
    self.frameWidth = (int)CGDisplayModeGetPixelWidth(mode);
    self.frameHeight = (int)CGDisplayModeGetPixelHeight(mode);
    CFRelease(mode);
  } else {
    self.frameWidth = (int)CGDisplayPixelsWide(displayID);
    self.frameHeight = (int)CGDisplayPixelsHigh(displayID);
  }

  dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(
    DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, DISPATCH_QUEUE_PRIORITY_HIGH
  );
  self.videoQueue = dispatch_queue_create("dev.lizardbyte.sunshine.sck.video", qos);

  dispatch_semaphore_t initSemaphore = dispatch_semaphore_create(0);
  __block BOOL initSuccess = NO;

  [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
    if (error) {
      NSLog(@"[SCCapture] Failed to get shareable content: %@", error.localizedDescription);
    } else {
      self.shareableContent = content;
      initSuccess = YES;
    }
    dispatch_semaphore_signal(initSemaphore);
  }];

  dispatch_semaphore_wait(initSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
  return initSuccess ? self : nil;
}

- (void)dealloc {
  [self stopCapture];
}

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight {
  self.frameWidth = frameWidth;
  self.frameHeight = frameHeight;
}

static NSString *pixelFormatName(OSType format) {
  char chars[5] = {
    (char)((format >> 24) & 0xFF),
    (char)((format >> 16) & 0xFF),
    (char)((format >> 8) & 0xFF),
    (char)(format & 0xFF),
    0,
  };
  return [NSString stringWithFormat:@"%s (0x%08x)", chars, format];
}

- (SCDisplay *)findDisplayWithID:(CGDirectDisplayID)displayID {
  for (SCDisplay *display in self.shareableContent.displays) {
    if (display.displayID == displayID) {
      return display;
    }
  }
  return nil;
}

- (BOOL)refreshShareableContent {
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block BOOL success = NO;

  [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
    if (!error && content) {
      self.shareableContent = content;
      success = YES;
    }
    dispatch_semaphore_signal(sem);
  }];

  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
  return success;
}

- (SCDisplay *)findDisplayWithIDRetrying:(CGDirectDisplayID)displayID {
  SCDisplay *display = [self findDisplayWithID:displayID];
  if (display) {
    return display;
  }

  for (int attempt = 1; attempt <= 3; attempt++) {
    NSLog(@"[SCCapture] Display %u not found in SCShareableContent, refreshing (attempt %d/3)", displayID, attempt);
    [NSThread sleepForTimeInterval:1.0];

    if ([self refreshShareableContent]) {
      display = [self findDisplayWithID:displayID];
      if (display) {
        NSLog(@"[SCCapture] Found display %u after refresh", displayID);
        return display;
      }
    }
  }

  return nil;
}

- (void)tearDownStream {
  if (!self.stream) {
    return;
  }

  dispatch_semaphore_t stopSemaphore = dispatch_semaphore_create(0);
  [self.stream stopCaptureWithCompletionHandler:^(NSError *error) {
    if (error) {
      NSLog(@"[SCCapture] Error stopping capture: %@", error.localizedDescription);
    }
    dispatch_semaphore_signal(stopSemaphore);
  }];
  dispatch_semaphore_wait(stopSemaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
  self.stream = nil;
  self.streamConfig = nil;
}

- (dispatch_semaphore_t)capture:(SCVideoFrameCallbackBlock)videoCallback {
  SCDisplay *display = [self findDisplayWithIDRetrying:self.displayID];
  if (!display) {
    NSLog(@"[SCCapture] Display not found after retries: %u", self.displayID);
    return nil;
  }

  @synchronized(self) {
    [self tearDownStream];
    self.stopping = NO;
    self.pixelFormatMismatch = NO;
    self.videoCallback = videoCallback;
    self.captureSignal = dispatch_semaphore_create(0);

    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.width = self.frameWidth;
    config.height = self.frameHeight;
    config.minimumFrameInterval = CMTimeMake(1, self.frameRate);
    config.pixelFormat = self.pixelFormat;
    config.queueDepth = 5;
    config.showsCursor = self.captureCursor;
    self.streamConfig = config;
    config.colorSpaceName = self.hdrDisplay ? kCGColorSpaceITUR_2020 : kCGColorSpaceDisplayP3;
    if (@available(macOS 15.0, *)) {
      if (self.hdrDisplay) {
        config.captureDynamicRange = SCCaptureDynamicRangeHDRLocalDisplay;
      }
    }

    NSError *error = nil;
    self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
    if (!self.stream) {
      NSLog(@"[SCCapture] Failed to create SCStream");
      self.captureSignal = nil;
      self.videoCallback = nil;
      return nil;
    }

    if (![self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.videoQueue error:&error]) {
      NSLog(@"[SCCapture] Failed to add video output: %@", error.localizedDescription);
      [self tearDownStream];
      self.captureSignal = nil;
      self.videoCallback = nil;
      return nil;
    }

    dispatch_semaphore_t startSemaphore = dispatch_semaphore_create(0);
    __block BOOL startSuccess = NO;

    [self.stream startCaptureWithCompletionHandler:^(NSError *error) {
      if (error) {
        NSLog(@"[SCCapture] Failed to start capture: %@", error.localizedDescription);
      } else {
        NSLog(@"[SCCapture] Capture started successfully");
        startSuccess = YES;
      }
      dispatch_semaphore_signal(startSemaphore);
    }];

    dispatch_semaphore_wait(startSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (!startSuccess) {
      [self tearDownStream];
      self.captureSignal = nil;
      self.videoCallback = nil;
      return nil;
    }

    return self.captureSignal;
  }
}

- (void)setCursorCapture:(BOOL)enabled {
  @synchronized(self) {
    if (self.captureCursor == enabled) {
      return;
    }
    self.captureCursor = enabled;

    if (!self.stream || !self.streamConfig || self.stopping) {
      return;
    }

    self.streamConfig.showsCursor = enabled;
    [self.stream updateConfiguration:self.streamConfig
                   completionHandler:^(NSError *error) {
                     if (error) {
                       NSLog(@"[SCCapture] Failed to update cursor capture: %@", error.localizedDescription);
                     } else {
                       NSLog(@"[SCCapture] Cursor capture %@", enabled ? @"enabled" : @"disabled");
                     }
                   }];
  }
}

- (void)stopCapture {
  @synchronized(self) {
    self.stopping = YES;
    [self tearDownStream];

    if (self.captureSignal) {
      dispatch_semaphore_signal(self.captureSignal);
      self.captureSignal = nil;
    }

    self.videoCallback = nil;

    if (self.lastValidSampleBuffer) {
      CFRelease(self.lastValidSampleBuffer);
      self.lastValidSampleBuffer = NULL;
    }
  }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
  NSLog(@"[SCCapture] Stream stopped with error: %@", error.localizedDescription);
  @synchronized(self) {
    self.stopping = YES;
    if (self.captureSignal) {
      dispatch_semaphore_signal(self.captureSignal);
    }
  }
}

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
  if (type != SCStreamOutputTypeScreen) {
    return;
  }

  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (!pixelBuffer) {
    SCVideoFrameCallbackBlock callback = nil;
    CMSampleBufferRef replaySampleBuffer = NULL;
    @synchronized(self) {
      if (self.lastValidSampleBuffer && !self.stopping && self.videoCallback) {
        replaySampleBuffer = (CMSampleBufferRef)CFRetain(self.lastValidSampleBuffer);
        callback = self.videoCallback;
      }
    }
    if (callback && replaySampleBuffer) {
      if (!callback(replaySampleBuffer)) {
        @synchronized(self) {
          self.stopping = YES;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          [self stopCapture];
        });
      }
      CFRelease(replaySampleBuffer);
    }
    return;
  }

  if (!self.loggedPixelFormat) {
    self.loggedPixelFormat = YES;
    OSType receivedFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    NSLog(@"[SCCapture] Received pixel format %@", pixelFormatName(receivedFormat));
    if (self.pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange && receivedFormat != self.pixelFormat) {
      NSLog(@"[SCCapture] Warning: requested P010 capture but received %@", pixelFormatName(receivedFormat));
      @synchronized(self) {
        self.pixelFormatMismatch = YES;
        self.stopping = YES;
        if (self.captureSignal) {
          dispatch_semaphore_signal(self.captureSignal);
        }
      }
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self stopCapture];
      });
      return;
    }
  }

  SCVideoFrameCallbackBlock callback = nil;
  @synchronized(self) {
    if (self.lastValidSampleBuffer) {
      CFRelease(self.lastValidSampleBuffer);
    }
    self.lastValidSampleBuffer = (CMSampleBufferRef)CFRetain(sampleBuffer);

    if (self.stopping) {
      return;
    }
    callback = self.videoCallback;
  }

  if (callback && !callback(sampleBuffer)) {
    @synchronized(self) {
      self.stopping = YES;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      [self stopCapture];
    });
  }
}

@end
