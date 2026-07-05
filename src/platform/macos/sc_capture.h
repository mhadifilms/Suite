/**
 * @file src/platform/macos/sc_capture.h
 * @brief Declarations for ScreenCaptureKit-based video capture on macOS 12.3+.
 */
#pragma once

#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

typedef bool (^SCVideoFrameCallbackBlock)(CMSampleBufferRef);

API_AVAILABLE(macos(12.3))
@interface SCCapture : NSObject <SCStreamDelegate, SCStreamOutput>

@property(nonatomic, assign) CGDirectDisplayID displayID;
@property(nonatomic, assign) int frameRate;
@property(nonatomic, assign) OSType pixelFormat;
@property(nonatomic, assign) int frameWidth;
@property(nonatomic, assign) int frameHeight;
@property(nonatomic, assign) BOOL hdrDisplay;
@property(nonatomic, assign) BOOL loggedPixelFormat;
@property(nonatomic, assign) BOOL pixelFormatMismatch;
@property(nonatomic, assign) BOOL captureCursor;

@property(nonatomic, strong) SCStream *stream;
@property(nonatomic, strong) SCStreamConfiguration *streamConfig;
@property(nonatomic, strong) SCShareableContent *shareableContent;
@property(nonatomic, strong) dispatch_queue_t videoQueue;
@property(nonatomic, copy) SCVideoFrameCallbackBlock videoCallback;
@property(nonatomic, strong) dispatch_semaphore_t captureSignal;
@property(nonatomic, assign) BOOL stopping;
@property(nonatomic, assign) CMSampleBufferRef lastValidSampleBuffer;

+ (BOOL)isAvailable;

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate;
- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight;
- (dispatch_semaphore_t)capture:(SCVideoFrameCallbackBlock)videoCallback;
- (void)setCursorCapture:(BOOL)enabled;
- (void)stopCapture;

@end
