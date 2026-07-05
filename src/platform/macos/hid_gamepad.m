/**
 * @file src/platform/macos/hid_gamepad.m
 * @brief Virtual HID gamepad implementation via IOHIDUserDevice.
 */
#import "hid_gamepad.h"
#import <IOKit/hidsystem/IOHIDUserDevice.h>
#import <mach/mach_time.h>

#define SF_DPAD_UP      0x0001
#define SF_DPAD_DOWN    0x0002
#define SF_DPAD_LEFT    0x0004
#define SF_DPAD_RIGHT   0x0008
#define SF_START        0x0010
#define SF_BACK         0x0020
#define SF_LEFT_STICK   0x0040
#define SF_RIGHT_STICK  0x0080
#define SF_LEFT_BUTTON  0x0100
#define SF_RIGHT_BUTTON 0x0200
#define SF_HOME         0x0400
#define SF_A            0x1000
#define SF_B            0x2000
#define SF_X            0x4000
#define SF_Y            0x8000

#define HAT_N     0
#define HAT_NE    1
#define HAT_E     2
#define HAT_SE    3
#define HAT_S     4
#define HAT_SW    5
#define HAT_W     6
#define HAT_NW    7
#define HAT_NONE  8

static const uint8_t kHIDReportDescriptor[] = {
  0x05, 0x01, 0x09, 0x04, 0xA1, 0x01, 0x85, 0x01,
  0x05, 0x09, 0x19, 0x01, 0x29, 0x10, 0x15, 0x00,
  0x25, 0x01, 0x95, 0x10, 0x75, 0x01, 0x81, 0x02,
  0x05, 0x01, 0x09, 0x39, 0x15, 0x00, 0x25, 0x07,
  0x35, 0x00, 0x46, 0x3B, 0x01, 0x65, 0x14, 0x75,
  0x04, 0x95, 0x01, 0x81, 0x42, 0x75, 0x04, 0x95,
  0x01, 0x81, 0x01, 0x05, 0x02, 0x09, 0xC5, 0x09,
  0xC4, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08,
  0x95, 0x02, 0x81, 0x02, 0x05, 0x01, 0x09, 0x30,
  0x09, 0x31, 0x09, 0x32, 0x09, 0x35, 0x16, 0x00,
  0x80, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x04,
  0x81, 0x02, 0xC0
};

@implementation HIDGamepad

+ (BOOL)isAvailable {
  static dispatch_once_t once;
  static BOOL available = NO;
  dispatch_once(&once, ^{
    NSDictionary *props = @{
      @kIOHIDVendorIDKey: @(0x1209),
      @kIOHIDProductIDKey: @(0x5853),
      @kIOHIDReportDescriptorKey: [NSData dataWithBytes:kHIDReportDescriptor length:sizeof(kHIDReportDescriptor)],
    };

    IOHIDUserDeviceRef testDevice = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, (__bridge CFDictionaryRef)props, 0);
    if (testDevice) {
      CFRelease(testDevice);
      available = YES;
    }
  });
  return available;
}

- (instancetype)initWithIndex:(int)index {
  self = [super init];
  if (self) {
    _gamepadIndex = index;
    _isConnected = NO;
    _hidDevice = NULL;
    _hidQueue = nil;
  }
  return self;
}

- (void)dealloc {
  [self disconnect];
  [super dealloc];
}

- (BOOL)createDevice {
  if (_hidDevice) {
    return YES;
  }

  NSString *queueLabel = [NSString stringWithFormat:@"com.sunshine.hid.gamepad.%d", _gamepadIndex];
  dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
  _hidQueue = dispatch_queue_create([queueLabel UTF8String], attr);

  NSDictionary *props = @{
    @kIOHIDVendorIDKey: @(0x1209),
    @kIOHIDProductIDKey: @(0x5853),
    @kIOHIDManufacturerKey: @"Sunshine Virtual Gamepad",
    @kIOHIDProductKey: [NSString stringWithFormat:@"Sunshine Gamepad %d", _gamepadIndex],
    @kIOHIDSerialNumberKey: [NSString stringWithFormat:@"SUNSHINE-%d", _gamepadIndex],
    @kIOHIDTransportKey: @"USB",
    @kIOHIDReportDescriptorKey: [NSData dataWithBytes:kHIDReportDescriptor length:sizeof(kHIDReportDescriptor)],
  };

  _hidDevice = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, (__bridge CFDictionaryRef)props, 0);
  if (!_hidDevice) {
    NSLog(@"[HIDGamepad] Failed to create IOHIDUserDevice for gamepad %d", _gamepadIndex);
    _hidQueue = nil;
    return NO;
  }

  IOHIDUserDeviceSetDispatchQueue(_hidDevice, _hidQueue);
  IOHIDUserDeviceActivate(_hidDevice);
  _isConnected = YES;

  HIDGamepadReport report = {0};
  report.reportId = 0x01;
  report.hatSwitch = HAT_NONE;

  IOReturn result = IOHIDUserDeviceHandleReportWithTimeStamp(
    _hidDevice, mach_absolute_time(), (const uint8_t *)&report, sizeof(report)
  );
  if (result != kIOReturnSuccess) {
    NSLog(@"[HIDGamepad] Warning: failed to send initial report for gamepad %d (0x%x)", _gamepadIndex, result);
  }

  NSLog(@"[HIDGamepad] Gamepad %d created successfully (IOHIDUserDevice)", _gamepadIndex);
  return YES;
}

static uint8_t dpadToHatSwitch(uint32_t buttons) {
  BOOL up = (buttons & SF_DPAD_UP) != 0;
  BOOL down = (buttons & SF_DPAD_DOWN) != 0;
  BOOL left = (buttons & SF_DPAD_LEFT) != 0;
  BOOL right = (buttons & SF_DPAD_RIGHT) != 0;

  if (up && right) return HAT_NE;
  if (up && left) return HAT_NW;
  if (down && right) return HAT_SE;
  if (down && left) return HAT_SW;
  if (up) return HAT_N;
  if (right) return HAT_E;
  if (down) return HAT_S;
  if (left) return HAT_W;
  return HAT_NONE;
}

static uint16_t mapButtons(uint32_t sf) {
  uint16_t hid = 0;
  if (sf & SF_A) hid |= (1 << 0);
  if (sf & SF_B) hid |= (1 << 1);
  if (sf & SF_X) hid |= (1 << 2);
  if (sf & SF_Y) hid |= (1 << 3);
  if (sf & SF_LEFT_BUTTON) hid |= (1 << 4);
  if (sf & SF_RIGHT_BUTTON) hid |= (1 << 5);
  if (sf & SF_BACK) hid |= (1 << 6);
  if (sf & SF_START) hid |= (1 << 7);
  if (sf & SF_LEFT_STICK) hid |= (1 << 8);
  if (sf & SF_RIGHT_STICK) hid |= (1 << 9);
  if (sf & SF_HOME) hid |= (1 << 10);
  return hid;
}

- (void)updateState:(uint32_t)buttons
         leftStickX:(int16_t)lsX
         leftStickY:(int16_t)lsY
        rightStickX:(int16_t)rsX
        rightStickY:(int16_t)rsY
        leftTrigger:(uint8_t)lt
       rightTrigger:(uint8_t)rt {
  if (!_isConnected || !_hidDevice || !_hidQueue) {
    return;
  }

  HIDGamepadReport report;
  report.reportId = 0x01;
  report.buttons = mapButtons(buttons);
  report.hatSwitch = dpadToHatSwitch(buttons);
  report.leftTrigger = lt;
  report.rightTrigger = rt;
  report.leftStickX = lsX;
  report.leftStickY = lsY;
  report.rightStickX = rsX;
  report.rightStickY = rsY;

  [self retain];
  dispatch_async(_hidQueue, ^{
    if (!self->_isConnected || !self->_hidDevice) {
      [self release];
      return;
    }

    IOReturn result = IOHIDUserDeviceHandleReportWithTimeStamp(
      self->_hidDevice, mach_absolute_time(), (const uint8_t *)&report, sizeof(report)
    );
    if (result != kIOReturnSuccess) {
      NSLog(@"[HIDGamepad] Failed to send report for gamepad %d (0x%x)", self->_gamepadIndex, result);
    }
    [self release];
  });
}

- (void)disconnect {
  if (!_hidDevice) {
    return;
  }

  _isConnected = NO;
  IOHIDUserDeviceRef device = _hidDevice;
  dispatch_queue_t queue = _hidQueue;
  int index = _gamepadIndex;
  _hidDevice = NULL;

  if (queue) {
    dispatch_sync(queue, ^{
    });
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    CFRetain(device);
    IOHIDUserDeviceSetCancelHandler(device, ^{
      CFRelease(device);
      dispatch_semaphore_signal(sem);
    });
    IOHIDUserDeviceCancel(device);
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0) {
      NSLog(@"[HIDGamepad] Timed out waiting for gamepad %d cancel handler", index);
    }
    CFRelease(device);
    _hidQueue = nil;
  } else {
    CFRelease(device);
  }

  NSLog(@"[HIDGamepad] Gamepad %d disconnected", index);
}

@end
