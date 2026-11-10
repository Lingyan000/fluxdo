#ifndef RUNNER_WINDOWS_UPDATE_H_
#define RUNNER_WINDOWS_UPDATE_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

void RegisterWindowsUpdate(flutter::BinaryMessenger* messenger, HWND window);

#endif  // RUNNER_WINDOWS_UPDATE_H_
