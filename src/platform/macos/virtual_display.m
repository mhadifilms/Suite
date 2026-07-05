/**
 * @file src/platform/macos/virtual_display.m
 * @brief CGVirtualDisplay-based virtual display management for macOS 14+.
 *
 * Spawns a helper subprocess (vd_helper) to create and hold the virtual display.
 * This avoids process-level state in Sunshine (TCC, frameworks, etc.) that prevents
 * CGVirtualDisplay from registering with WindowServer when created in-process.
 *
 * This file is compiled with ARC (-fobjc-arc). See macos.cmake.
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <errno.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <unistd.h>
#include "virtual_display.h"

extern char **environ;

static pthread_mutex_t vd_mutex = PTHREAD_MUTEX_INITIALIZER;
static pid_t vd_helper_pid = 0;
static uint32_t vd_display_id = 0;

static NSString *displayIDPath(void) {
  return [NSString stringWithFormat:@"/tmp/sunshine_vd_id.%u", getuid()];
}

static NSString *helperPIDPath(void) {
  return [NSString stringWithFormat:@"/tmp/sunshine_vd_pid.%u", getuid()];
}

static void remove_state_files(void) {
  [[NSFileManager defaultManager] removeItemAtPath:displayIDPath() error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:helperPIDPath() error:nil];
}

static void terminate_helper(pid_t pid) {
  if (pid <= 0) return;

  kill(pid, SIGTERM);
  int status = 0;
  for (int i = 0; i < 10; i++) {
    pid_t result = waitpid(pid, &status, WNOHANG);
    if (result == pid || (result < 0 && errno == ECHILD)) {
      return;
    }
    usleep(100000);
  }

  NSLog(@"[Sunshine] vd_helper pid=%d did not exit after SIGTERM; sending SIGKILL", pid);
  kill(pid, SIGKILL);
  waitpid(pid, &status, 0);
}

static bool process_is_running(pid_t pid) {
  if (pid <= 0) {
    return false;
  }

  return kill(pid, 0) == 0 || errno == EPERM;
}

static NSString *processPath(pid_t pid) {
  char pathbuf[PROC_PIDPATHINFO_MAXSIZE] = {0};
  const int len = proc_pidpath(pid, pathbuf, sizeof(pathbuf));
  if (len <= 0) {
    return nil;
  }

  return [[NSString stringWithUTF8String:pathbuf] stringByResolvingSymlinksInPath];
}

static bool process_matches_helper(pid_t pid, NSString *expected_helper) {
  NSString *actual = processPath(pid);
  if (!actual || !expected_helper) {
    return false;
  }

  NSString *expected = [expected_helper stringByResolvingSymlinksInPath];
  return [actual isEqualToString:expected];
}

static void terminate_recorded_helper(pid_t pid, NSString *expected_helper) {
  if (pid <= 0) {
    return;
  }

  if (!process_matches_helper(pid, expected_helper)) {
    NSLog(@"[Sunshine] Refusing to terminate recorded pid=%d because it is not %@", pid, expected_helper);
    return;
  }

  kill(pid, SIGTERM);
  for (int i = 0; i < 10; i++) {
    if (!process_is_running(pid)) {
      return;
    }
    if (!process_matches_helper(pid, expected_helper)) {
      NSLog(@"[Sunshine] Recorded helper pid=%d changed identity while terminating", pid);
      return;
    }
    usleep(100000);
  }

  NSLog(@"[Sunshine] Recorded stale vd_helper pid=%d did not exit after SIGTERM; sending SIGKILL", pid);
  kill(pid, SIGKILL);
  for (int i = 0; i < 10; i++) {
    if (!process_is_running(pid) || !process_matches_helper(pid, expected_helper)) {
      return;
    }
    usleep(100000);
  }
}

static pid_t read_recorded_helper_pid(void) {
  NSString *pidString = [NSString stringWithContentsOfFile:helperPIDPath()
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
  if (!pidString) {
    return 0;
  }

  return (pid_t)[pidString intValue];
}

static void cleanup_recorded_helper(pid_t current_helper_pid, NSString *expected_helper) {
  pid_t recorded_pid = read_recorded_helper_pid();
  if (recorded_pid <= 0 || recorded_pid == current_helper_pid) {
    return;
  }

  if (process_is_running(recorded_pid)) {
    NSLog(@"[Sunshine] Cleaning up recorded stale vd_helper pid=%d", recorded_pid);
    terminate_recorded_helper(recorded_pid, expected_helper);
  }

  remove_state_files();
}

static void write_state_files(uint32_t displayID, pid_t pid) {
  [@(displayID).stringValue writeToFile:displayIDPath()
                             atomically:YES
                               encoding:NSUTF8StringEncoding
                                  error:nil];
  [@(pid).stringValue writeToFile:helperPIDPath()
                       atomically:YES
                         encoding:NSUTF8StringEncoding
                            error:nil];
}

static NSString *helperPath(void) {
  NSString *mainExe = [[NSBundle mainBundle] executablePath];
  if (!mainExe) {
    char buf[4096];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) == 0) {
      mainExe = [[NSString stringWithUTF8String:buf] stringByResolvingSymlinksInPath];
    }
  }
  if (!mainExe) return nil;
  NSString *dir = [mainExe stringByDeletingLastPathComponent];
  return [dir stringByAppendingPathComponent:@"vd_helper"];
}

uint32_t virtual_display_create(int width, int height, int fps) {
  NSString *helper = helperPath();
  if (!helper) {
    NSLog(@"[Sunshine] Could not determine vd_helper path");
    return 0;
  }

  pthread_mutex_lock(&vd_mutex);
  pid_t old_pid = vd_helper_pid;
  uint32_t old_id = vd_display_id;
  vd_helper_pid = 0;
  vd_display_id = 0;
  pthread_mutex_unlock(&vd_mutex);

  cleanup_recorded_helper(old_pid, helper);

  if (old_pid > 0) {
    NSLog(@"[Sunshine] Killing existing vd_helper (pid=%d, display=%u) before creating new one",
          old_pid, old_id);
    terminate_helper(old_pid);
  }

  if (![[NSFileManager defaultManager] isExecutableFileAtPath:helper]) {
    NSLog(@"[Sunshine] vd_helper not found at: %@", helper);
    return 0;
  }

  NSLog(@"[Sunshine] Spawning vd_helper: %@ %d %d %d", helper, width, height, fps);

  int pipefd[2];
  if (pipe(pipefd) != 0) {
    NSLog(@"[Sunshine] pipe() failed: %s", strerror(errno));
    return 0;
  }

  char widthStr[16], heightStr[16], fpsStr[16];
  snprintf(widthStr, sizeof(widthStr), "%d", width);
  snprintf(heightStr, sizeof(heightStr), "%d", height);
  snprintf(fpsStr, sizeof(fpsStr), "%d", fps);

  const char *argv[] = {
    [helper fileSystemRepresentation],
    widthStr,
    heightStr,
    fpsStr,
    NULL
  };

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
  posix_spawn_file_actions_addclose(&actions, pipefd[0]);
  posix_spawn_file_actions_addclose(&actions, pipefd[1]);

  pid_t pid;
  int err = posix_spawn(&pid, argv[0], &actions, NULL, (char *const *)argv, environ);
  posix_spawn_file_actions_destroy(&actions);
  close(pipefd[1]);

  if (err != 0) {
    NSLog(@"[Sunshine] posix_spawn failed: %s", strerror(err));
    close(pipefd[0]);
    return 0;
  }

  NSLog(@"[Sunshine] vd_helper spawned (pid=%d)", pid);

  char buf[64] = {0};
  ssize_t n = 0;
  fd_set readfds;
  struct timeval tv;
  tv.tv_sec = 10;
  tv.tv_usec = 0;
  FD_ZERO(&readfds);
  FD_SET(pipefd[0], &readfds);

  int sel = select(pipefd[0] + 1, &readfds, NULL, NULL, &tv);
  if (sel > 0) {
    n = read(pipefd[0], buf, sizeof(buf) - 1);
  }
  close(pipefd[0]);

  if (n <= 0) {
    NSLog(@"[Sunshine] vd_helper produced no output, killing");
    terminate_helper(pid);
    remove_state_files();
    return 0;
  }

  uint32_t displayID = (uint32_t)strtoul(buf, NULL, 10);
  if (displayID == 0) {
    NSLog(@"[Sunshine] vd_helper returned displayID=0, killing");
    terminate_helper(pid);
    remove_state_files();
    return 0;
  }

  pthread_mutex_lock(&vd_mutex);
  vd_helper_pid = pid;
  vd_display_id = displayID;
  pthread_mutex_unlock(&vd_mutex);

  NSLog(@"[Sunshine] Virtual display %u created via vd_helper (pid=%d)", displayID, pid);

  write_state_files(displayID, pid);

  CGDirectDisplayID activeDisplays[32];
  uint32_t displayCount = 0;
  BOOL found = NO;
  if (CGGetActiveDisplayList(32, activeDisplays, &displayCount) == kCGErrorSuccess) {
    for (uint32_t i = 0; i < displayCount; i++) {
      if (activeDisplays[i] == displayID) { found = YES; break; }
    }
    NSLog(@"[Sunshine] Parent sees display %u: %@ in CGGetActiveDisplayList (%u total)",
          displayID, found ? @"FOUND" : @"NOT found", displayCount);
  }
  if (!found) {
    NSLog(@"[Sunshine] Parent could not see virtual display %u as active, killing helper", displayID);
    pthread_mutex_lock(&vd_mutex);
    if (vd_helper_pid == pid) {
      vd_helper_pid = 0;
      vd_display_id = 0;
    }
    pthread_mutex_unlock(&vd_mutex);
    terminate_helper(pid);
    remove_state_files();
    return 0;
  }

  return displayID;
}

void virtual_display_destroy(void) {
  pthread_mutex_lock(&vd_mutex);
  uint32_t old_id = vd_display_id;
  pid_t old_pid = vd_helper_pid;
  vd_helper_pid = 0;
  vd_display_id = 0;
  pthread_mutex_unlock(&vd_mutex);

  if (old_pid <= 0) {
    remove_state_files();
    return;
  }

  NSLog(@"[Sunshine] Destroying virtual display %u (killing vd_helper pid=%d)", old_id, old_pid);
  terminate_helper(old_pid);
  NSLog(@"[Sunshine] Destroyed virtual display %u", old_id);
  remove_state_files();
}

uint32_t virtual_display_get_id(void) {
  pthread_mutex_lock(&vd_mutex);
  uint32_t result = vd_display_id;
  pthread_mutex_unlock(&vd_mutex);
  return result;
}

bool virtual_display_is_ready(void) {
  uint32_t displayID = virtual_display_get_id();
  if (displayID == 0) {
    return false;
  }

  CGDirectDisplayID cgDisplayID = (CGDirectDisplayID)displayID;
  return CGDisplayIsOnline(cgDisplayID) && CGDisplayIsActive(cgDisplayID);
}
