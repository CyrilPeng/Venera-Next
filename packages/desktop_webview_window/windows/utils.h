//
// Created by yangbin on 2021/11/11.
//

#ifndef DESKTOP_WEBVIEW_WINDOW_WINDOWS_UTILS_H_
#define DESKTOP_WEBVIEW_WINDOW_WINDOWS_UTILS_H_

#include <windows.h>
#include "wil/wrl.h"

#include <string>

namespace webview_window {

const auto MONITOR_CENTER = 0x0001;        // center rect to monitor
const auto MONITOR_CLIP = 0x0000;      // clip rect to monitor
const auto MONITOR_WORKAREA = 0x0002;        // use monitor work area
const auto MONITOR_AREA = 0x0000;        // use monitor entire area

//
//  ClipOrCenterRectToMonitor
//
//  The most common problem apps have when running on a
//  multimonitor system is that they "clip" or "pin" windows
//  based on the SM_CXSCREEN and SM_CYSCREEN system metrics.
//  Because of app compatibility reasons these system metrics
//  return the size of the primary monitor.
//
//  This shows how you use the multi-monitor functions
//  to do the same thing.
//
void ClipOrCenterRectToMonitor(LPRECT prc, UINT flags);

void ClipOrCenterWindowToMonitor(HWND hwnd, UINT flags);

bool SetWindowBackgroundTransparent(HWND hwnd);

const wchar_t *RegisterWindowClass(LPCWSTR class_name, WNDPROC wnd_proc);

void UnregisterWindowClass(LPCWSTR class_name);

std::string ConvertLPCWSTRToString(LPCWSTR lpcwszStr);

}  // namespace webview_window

#endif //DESKTOP_WEBVIEW_WINDOW_WINDOWS_UTILS_H_
