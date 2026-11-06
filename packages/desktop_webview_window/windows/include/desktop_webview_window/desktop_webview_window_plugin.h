#ifndef FLUTTER_PLUGIN_WEBVIEW_WINDOW_PLUGIN_H_
#define FLUTTER_PLUGIN_WEBVIEW_WINDOW_PLUGIN_H_

#include <flutter_plugin_registrar.h>

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

FLUTTER_PLUGIN_EXPORT void DesktopWebviewWindowPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_WEBVIEW_WINDOW_PLUGIN_H_
