#include "external_route_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <roapi.h>
#include <shellapi.h>
#include <windows.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.Audio.h>
#include <winrt/base.h>

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <variant>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Devices::Enumeration::DeviceInformation;
using winrt::Windows::Foundation::IAsyncInfo;
using winrt::Windows::Media::Audio::AudioPlaybackConnection;
using winrt::Windows::Media::Audio::AudioPlaybackConnectionOpenResultStatus;
using winrt::Windows::Media::Audio::AudioPlaybackConnectionState;

constexpr char kChannelName[] = "com.machinee.audioshare/external_route";

struct BluetoothState {
  std::mutex mutex;
  AudioPlaybackConnection connection{nullptr};
  winrt::hstring device_id;
  IAsyncInfo pending_operation{nullptr};
  std::string message = "Bluetooth audio receiver is stopped.";
  uint64_t generation = 0;
  bool shutting_down = false;
};

struct BluetoothResources {
  AudioPlaybackConnection connection{nullptr};
  IAsyncInfo pending_operation{nullptr};
  uint64_t generation = 0;
};

EncodableValue Status(const std::string& mode, const std::string& message) {
  return EncodableValue(EncodableMap{
      {EncodableValue("mode"), EncodableValue(mode)},
      {EncodableValue("message"), EncodableValue(message)},
  });
}

std::string ErrorMessage(const char* context, const winrt::hresult_error& error) {
  std::string message(context);
  message += ": ";
  message += winrt::to_string(error.message());
  return message;
}

BluetoothResources ResetBluetoothState(
    const std::shared_ptr<BluetoothState>& state,
    const std::string& message,
    bool shutting_down = false) {
  std::lock_guard<std::mutex> lock(state->mutex);
  BluetoothResources resources{
      state->connection,
      state->pending_operation,
      ++state->generation,
  };
  state->connection = nullptr;
  state->device_id.clear();
  state->pending_operation = nullptr;
  state->message = message;
  state->shutting_down = state->shutting_down || shutting_down;
  return resources;
}

void CloseBluetoothResources(BluetoothResources resources) {
  if (resources.pending_operation) {
    try {
      resources.pending_operation.Cancel();
    } catch (const winrt::hresult_error&) {
      // The operation may have completed between ResetBluetoothState and here.
    }
  }
  if (resources.connection) {
    try {
      resources.connection.Close();
    } catch (const winrt::hresult_error&) {
      // The device may already have disappeared. Releasing it is still required.
    }
  }
}

bool IsCurrentGeneration(const std::shared_ptr<BluetoothState>& state,
                         uint64_t generation) {
  std::lock_guard<std::mutex> lock(state->mutex);
  return !state->shutting_down && state->generation == generation;
}

bool SetPendingOperation(const std::shared_ptr<BluetoothState>& state,
                         uint64_t generation,
                         const IAsyncInfo& operation) {
  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->shutting_down || state->generation != generation) {
    return false;
  }
  state->pending_operation = operation;
  return true;
}

void ClearPendingOperation(const std::shared_ptr<BluetoothState>& state,
                           uint64_t generation) {
  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->generation == generation) {
    state->pending_operation = nullptr;
  }
}

void SetConnectionError(const std::shared_ptr<BluetoothState>& state,
                        uint64_t generation,
                        const std::string& message) {
  std::lock_guard<std::mutex> lock(state->mutex);
  if (!state->shutting_down && state->generation == generation) {
    state->pending_operation = nullptr;
    state->message = message;
  }
}

bool InstallConnection(const std::shared_ptr<BluetoothState>& state,
                       uint64_t generation,
                       const AudioPlaybackConnection& connection,
                       const winrt::hstring& device_id) {
  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->shutting_down || state->generation != generation) {
    return false;
  }
  state->pending_operation = nullptr;
  state->connection = connection;
  state->device_id = device_id;
  state->message = "Bluetooth audio receiver is connected.";
  return true;
}

std::pair<winrt::hstring, std::string> ConnectedDevice(
    const std::shared_ptr<BluetoothState>& state) {
  std::lock_guard<std::mutex> lock(state->mutex);
  try {
    if (state->connection &&
        state->connection.State() == AudioPlaybackConnectionState::Opened) {
      return {state->device_id, state->message};
    }
  } catch (const winrt::hresult_error&) {
    // A disconnected device is reported as stopped below.
  }
  return {winrt::hstring(), "Bluetooth audio receiver is stopped."};
}

template <typename Work>
void RunInBackground(Work work) {
  std::thread([work = std::move(work)]() mutable {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    work();
    winrt::uninit_apartment();
  }).detach();
}

std::string StringArg(const EncodableValue* args, const std::string& key) {
  if (!args || !std::holds_alternative<EncodableMap>(*args)) {
    return {};
  }
  const auto& map = std::get<EncodableMap>(*args);
  const auto it = map.find(EncodableValue(key));
  if (it == map.end() || !std::holds_alternative<std::string>(it->second)) {
    return {};
  }
  return std::get<std::string>(it->second);
}

bool LaunchBluetoothSettings() {
  const HINSTANCE result = ShellExecuteW(nullptr, L"open", L"ms-settings:bluetooth",
                                         nullptr, nullptr, SW_SHOWNORMAL);
  return reinterpret_cast<intptr_t>(result) > 32;
}

}  // namespace

std::function<void()> RegisterExternalRouteChannel(
    flutter::BinaryMessenger* messenger) {
  const HRESULT ro_result = RoInitialize(RO_INIT_MULTITHREADED);
  const bool ro_initialized = SUCCEEDED(ro_result);

  auto channel = std::make_shared<flutter::MethodChannel<EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  auto state = std::make_shared<BluetoothState>();

  channel->SetMethodCallHandler(
      [state](const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const auto& method = call.method_name();
        if (method == "listBluetoothDevices") {
          RunInBackground(
              [state, result = std::move(result)]() mutable {
                try {
                  const auto devices = DeviceInformation::FindAllAsync(
                                           AudioPlaybackConnection::GetDeviceSelector())
                                           .get();
                  const auto connected_device = ConnectedDevice(state).first;
                  EncodableList list;
                  for (const auto& device : devices) {
                    list.emplace_back(EncodableMap{
                        {EncodableValue("id"),
                         EncodableValue(winrt::to_string(device.Id()))},
                        {EncodableValue("name"),
                         EncodableValue(winrt::to_string(device.Name()))},
                        {EncodableValue("isConnected"),
                         EncodableValue(!connected_device.empty() &&
                                        device.Id() == connected_device)},
                    });
                  }
                  result->Success(EncodableValue(list));
                } catch (const winrt::hresult_error& error) {
                  result->Error(
                      "bluetooth_enumeration_failed",
                      ErrorMessage("Could not enumerate Bluetooth audio devices", error));
                }
              });
          return;
        }
        if (method == "startBluetoothSink") {
          const std::string device_id = StringArg(call.arguments(), "deviceId");
          if (device_id.empty()) {
            result->Success(Status("error", "Missing Bluetooth device ID."));
            return;
          }
          auto old_resources = ResetBluetoothState(
              state, "Bluetooth audio receiver is starting.");
          const uint64_t generation = old_resources.generation;
          RunInBackground(
              [state, old_resources = std::move(old_resources), generation,
               device_id, result = std::move(result)]() mutable {
                CloseBluetoothResources(std::move(old_resources));
                AudioPlaybackConnection connection{nullptr};
                try {
                  if (!IsCurrentGeneration(state, generation)) {
                    result->Success(Status("stopped", "Bluetooth startup was cancelled."));
                    return;
                  }

                  const winrt::hstring id = winrt::to_hstring(device_id);
                  connection = AudioPlaybackConnection::TryCreateFromId(id);
                  if (!connection) {
                    const std::string message =
                        "Windows could not create a Bluetooth audio connection. Pair the phone first.";
                    SetConnectionError(state, generation, message);
                    result->Success(Status("error", message));
                    return;
                  }

                  const auto start_operation = connection.StartAsync();
                  if (!SetPendingOperation(
                          state, generation, start_operation.as<IAsyncInfo>())) {
                    start_operation.Cancel();
                    connection.Close();
                    result->Success(Status("stopped", "Bluetooth startup was cancelled."));
                    return;
                  }
                  start_operation.get();
                  ClearPendingOperation(state, generation);

                  const auto open_operation = connection.OpenAsync();
                  if (!SetPendingOperation(
                          state, generation, open_operation.as<IAsyncInfo>())) {
                    open_operation.Cancel();
                    connection.Close();
                    result->Success(Status("stopped", "Bluetooth startup was cancelled."));
                    return;
                  }
                  const auto open_result = open_operation.get();
                  ClearPendingOperation(state, generation);

                  if (open_result.Status() !=
                      AudioPlaybackConnectionOpenResultStatus::Success) {
                    connection.Close();
                    const std::string message =
                        "Windows could not open the Bluetooth audio connection (status " +
                        std::to_string(static_cast<int>(open_result.Status())) + ").";
                    SetConnectionError(state, generation, message);
                    result->Success(Status("error", message));
                    return;
                  }

                  if (!InstallConnection(state, generation, connection, id)) {
                    connection.Close();
                    result->Success(Status("stopped", "Bluetooth startup was cancelled."));
                    return;
                  }
                  result->Success(Status(
                      "connected", "Bluetooth audio receiver is connected."));
                } catch (const winrt::hresult_error& error) {
                  if (connection) {
                    try {
                      connection.Close();
                    } catch (const winrt::hresult_error&) {
                    }
                  }
                  const bool current = IsCurrentGeneration(state, generation);
                  const std::string message = current
                      ? ErrorMessage("Bluetooth audio connection failed", error)
                      : "Bluetooth startup was cancelled.";
                  if (current) {
                    SetConnectionError(state, generation, message);
                  }
                  result->Success(Status(current ? "error" : "stopped", message));
                }
              });
          return;
        }
        if (method == "stopBluetoothSink") {
          auto resources = ResetBluetoothState(
              state, "Bluetooth audio receiver is stopped.");
          RunInBackground(
              [resources = std::move(resources)]() mutable {
                CloseBluetoothResources(std::move(resources));
              });
          result->Success(Status("stopped", "Bluetooth audio receiver is stopped."));
          return;
        }
        if (method == "getBluetoothSinkStatus") {
          const auto connected_device = ConnectedDevice(state);
          result->Success(Status(connected_device.first.empty() ? "stopped" : "connected",
                                 connected_device.second));
          return;
        }
        if (method == "openBluetoothSettings") {
          if (LaunchBluetoothSettings()) {
            result->Success(Status("ready", "Opened Windows Bluetooth settings."));
          } else {
            result->Success(Status("error", "Could not open Windows Bluetooth settings."));
          }
          return;
        }
        result->NotImplemented();
      });

  return [channel, state, ro_initialized]() {
    channel->SetMethodCallHandler(nullptr);
    auto resources = ResetBluetoothState(
        state, "Bluetooth audio receiver is stopped.", true);
    RunInBackground(
        [resources = std::move(resources)]() mutable {
          CloseBluetoothResources(std::move(resources));
        });
    if (ro_initialized) RoUninitialize();
  };
}
