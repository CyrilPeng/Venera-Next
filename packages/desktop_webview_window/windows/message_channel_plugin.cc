//
// Created by yangbin on 2021/11/15.
//

#include <flutter/plugin_registrar.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "message_channel_plugin.h"

const auto kClientChannelName = "webview_message/client_channel";

namespace {

using FlutterMethodChannel = std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>;

class ClientMessageChannelPlugin {
 public:
  explicit ClientMessageChannelPlugin(FlutterMethodChannel channel);

  void InvokeMethod(
      const std::string &method,
      std::unique_ptr<flutter::EncodableValue> arguments) {
    channel_->InvokeMethod(method, std::move(arguments), nullptr);
  }

 private:
  FlutterMethodChannel channel_;
};

class ServerMessageChannelPlugin {
 public:

  void AddClient(std::shared_ptr<ClientMessageChannelPlugin> client) {
    client_set_.insert(std::move(client));
  }

  void RemoveClient(const std::shared_ptr<ClientMessageChannelPlugin> &client) {
    client_set_.erase(client);
  }

  void DispatchMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &call,
      ClientMessageChannelPlugin *client_from);

 private:
  std::set<std::shared_ptr<ClientMessageChannelPlugin>> client_set_;
};

std::shared_ptr<ServerMessageChannelPlugin> g_server_channel_plugin;

class ClientPluginProxy : public flutter::Plugin {

 public:
  explicit ClientPluginProxy(std::shared_ptr<ClientMessageChannelPlugin> client)
      : client_(std::move(client)) {
    assert(g_server_channel_plugin);
    g_server_channel_plugin->AddClient(client_);
  }

  ~ClientPluginProxy() override {
    g_server_channel_plugin->RemoveClient(client_);
  }

 private:
  std::shared_ptr<ClientMessageChannelPlugin> client_;
};

}

void RegisterClientMessageChannelPlugin(FlutterDesktopPluginRegistrarRef registrar) {
  auto registrar_windows = flutter::PluginRegistrarManager::GetInstance()
      ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  auto channel = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar_windows->messenger(), kClientChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  if (!g_server_channel_plugin) {
    g_server_channel_plugin = std::make_shared<ServerMessageChannelPlugin>();
  }
  assert(g_server_channel_plugin);
  auto client_plugin = std::make_shared<ClientMessageChannelPlugin>(channel);
  registrar_windows->AddPlugin(std::make_unique<ClientPluginProxy>(client_plugin));
}

ClientMessageChannelPlugin::ClientMessageChannelPlugin(
    FlutterMethodChannel channel
) : channel_(std::move(channel)) {
  channel_->SetMethodCallHandler([this](const auto &call, auto result) {
    if (g_server_channel_plugin) {
      g_server_channel_plugin->DispatchMethodCall(call, this);
      result->Success();
    }
  });
}

void ServerMessageChannelPlugin::DispatchMethodCall(
    const flutter::MethodCall<> &call,
    ClientMessageChannelPlugin *client_from) {
  for (const auto &item: client_set_) {
    if (item.get() != client_from) {
      item->InvokeMethod(
          call.method_name(),
          std::make_unique<flutter::EncodableValue>(*call.arguments()));
    }
  }
}