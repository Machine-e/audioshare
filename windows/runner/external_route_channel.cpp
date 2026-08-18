#include "external_route_channel.h"
#include "sink_state_machine.h"

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

#include <condition_variable>
#include <cstdint>
#include <deque>
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
using MethodResult = flutter::MethodResult<EncodableValue>;
using winrt::Windows::Devices::Enumeration::DeviceInformation;
using winrt::Windows::Foundation::IAsyncInfo;
using winrt::Windows::Media::Audio::AudioPlaybackConnection;
using winrt::Windows::Media::Audio::AudioPlaybackConnectionOpenResultStatus;
using winrt::Windows::Media::Audio::AudioPlaybackConnectionState;

constexpr char kChannelName[] = "com.machinee.audioshare/external_route";
constexpr char kStoppedMessage[] = "Bluetooth audio receiver is stopped.";

class BackgroundExecutor {
 public:
  BackgroundExecutor() : worker_([this] { Run(); }) {}
  ~BackgroundExecutor() { Stop(); }
  template <typename F>
  bool Post(F&& work) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_) return false;
    tasks_.push_back(std::make_unique<Task<F>>(std::forward<F>(work)));
    cv_.notify_one();
    return true;
  }
  void Stop() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_) return;
      stopping_ = true;
    }
    cv_.notify_one();
    if (worker_.joinable()) worker_.join();
  }
 private:
  struct TaskBase { virtual ~TaskBase() = default; virtual void Invoke() = 0; };
  template <typename F> struct Task final : TaskBase {
    explicit Task(F&& f) : f_(std::move(f)) {}
    void Invoke() override { f_(); }
    F f_;
  };
  void Run() noexcept {
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      for (;;) {
        std::unique_ptr<TaskBase> task;
        {
          std::unique_lock<std::mutex> lock(mutex_);
          cv_.wait(lock, [this] { return stopping_ || !tasks_.empty(); });
          if (tasks_.empty()) break;
          task = std::move(tasks_.front());
          tasks_.pop_front();
        }
        try { task->Invoke(); } catch (...) { /* Keep the executor alive. */ }
      }
      winrt::uninit_apartment();
    } catch (...) { /* Apartment initialization failed; never escape the thread. */ }
  }
  std::mutex mutex_;
  std::condition_variable cv_;
  std::deque<std::unique_ptr<TaskBase>> tasks_;
  bool stopping_ = false;
  std::thread worker_;
};

struct BluetoothState {
  std::mutex mutex;
  AudioPlaybackConnection connection{nullptr};
  winrt::event_token state_changed_token{};
  bool has_state_changed_token = false;
  winrt::hstring device_id;
  IAsyncInfo pending_operation{nullptr};
  std::unique_ptr<MethodResult> waiter;
  std::string message = kStoppedMessage;
  uint64_t generation = 0;
  audioshare::SinkStateMachine reducer;
  bool shutting_down = false;
};
struct BluetoothResources {
  AudioPlaybackConnection connection{nullptr};
  winrt::event_token token{};
  bool has_token = false;
  IAsyncInfo pending_operation{nullptr};
  std::unique_ptr<MethodResult> waiter;
  uint64_t generation = 0;
};

EncodableValue Status(const std::string& mode, const std::string& message) {
  return EncodableValue(EncodableMap{{EncodableValue("mode"), EncodableValue(mode)},
                                    {EncodableValue("message"), EncodableValue(message)}});
}
std::string ErrorMessage(const char* context, const winrt::hresult_error& error) {
  return std::string(context) + ": " + winrt::to_string(error.message());
}
BluetoothResources ResetState(const std::shared_ptr<BluetoothState>& state,
                              const std::string& message, bool shutdown = false) {
  std::lock_guard<std::mutex> lock(state->mutex);
  BluetoothResources out{state->connection, state->state_changed_token,
                         state->has_state_changed_token, state->pending_operation,
                         std::move(state->waiter), ++state->generation};
  state->connection = nullptr;
  state->has_state_changed_token = false;
  state->device_id.clear();
  state->pending_operation = nullptr;
  state->message = message;
  state->reducer.Stop();
  state->shutting_down = state->shutting_down || shutdown;
  return out;
}
void CloseResources(BluetoothResources resources, bool complete_waiter = true) {
  if (resources.pending_operation) try { resources.pending_operation.Cancel(); } catch (...) {}
  if (resources.connection && resources.has_token)
    try { resources.connection.StateChanged(resources.token); } catch (...) {}
  if (resources.connection) try { resources.connection.Close(); } catch (...) {}
  if (complete_waiter && resources.waiter)
    resources.waiter->Success(Status("stopped", kStoppedMessage));
}
void ReleaseResources(const std::shared_ptr<BackgroundExecutor>& executor,
                      BluetoothResources resources,
                      bool complete_waiter = true) {
  if (resources.pending_operation) {
    try {
      resources.pending_operation.Cancel();
    } catch (...) {
    }
    resources.pending_operation = nullptr;
  }
  if (complete_waiter && resources.waiter) {
    resources.waiter->Success(Status("stopped", kStoppedMessage));
  }
  resources.waiter.reset();
  auto shared_resources =
      std::make_shared<BluetoothResources>(std::move(resources));
  if (executor && executor->Post([shared_resources]() mutable {
        CloseResources(std::move(*shared_resources), false);
      })) {
    return;
  }
  CloseResources(std::move(*shared_resources), false);
}
bool Current(const std::shared_ptr<BluetoothState>& state, uint64_t generation) {
  std::lock_guard<std::mutex> lock(state->mutex);
  return !state->shutting_down && state->generation == generation;
}
bool SetPending(const std::shared_ptr<BluetoothState>& state, uint64_t generation,
                const IAsyncInfo& operation) {
  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->shutting_down || state->generation != generation) return false;
  state->pending_operation = operation;
  return true;
}
void ClearPending(const std::shared_ptr<BluetoothState>& state, uint64_t generation) {
  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->generation == generation) state->pending_operation = nullptr;
}
void SetError(const std::shared_ptr<BluetoothState>& state, uint64_t generation,
              const std::string& message) {
  std::lock_guard<std::mutex> lock(state->mutex);
  if (!state->shutting_down && state->generation == generation) {
    state->pending_operation = nullptr;
    state->message = message;
  }
}
bool TakeConnection(const std::shared_ptr<BluetoothState>& state,
                    uint64_t generation,
                    const AudioPlaybackConnection& connection,
                    const std::string& message,
                    BluetoothResources& resources) {
  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->shutting_down || state->generation != generation ||
      !state->connection || state->connection != connection) {
    return false;
  }
  resources = {state->connection, state->state_changed_token,
               state->has_state_changed_token, state->pending_operation,
               std::move(state->waiter), state->generation};
  state->connection = nullptr;
  state->has_state_changed_token = false;
  state->device_id.clear();
  state->pending_operation = nullptr;
  state->message = message;
  return true;
}
const char* Mode(audioshare::SinkState state) {
  switch (state) {
    case audioshare::SinkState::waitingForRoute: return "waitingForRoute";
    case audioshare::SinkState::opened: return "opened";
    case audioshare::SinkState::disconnected: return "disconnected";
    case audioshare::SinkState::error: return "error";
    default: return "stopped";
  }
}
const char* StateMessage(audioshare::SinkState state) {
  switch (state) {
    case audioshare::SinkState::waitingForRoute:
      return "Waiting for the phone to select this PC as media output.";
    case audioshare::SinkState::opened:
      return "The phone media route is connected.";
    case audioshare::SinkState::disconnected:
      return "The phone media route disconnected.";
    case audioshare::SinkState::error:
      return "Could not read Bluetooth connection state.";
    default: return kStoppedMessage;
  }
}
void OnStateChanged(const std::weak_ptr<BluetoothState>& weak_state,
                    const std::weak_ptr<BackgroundExecutor>& weak_executor,
                    uint64_t generation,
                    const AudioPlaybackConnection& sender) noexcept {
  AudioPlaybackConnectionState connection_state =
      AudioPlaybackConnectionState::Closed;
  bool state_read_failed = false;
  try {
    connection_state = sender.State();
  } catch (...) {
    state_read_failed = true;
  }
  auto state = weak_state.lock();
  if (!state) return;
  if (state_read_failed) {
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (state->generation != generation || !state->reducer.Error(generation)) return;
    }
    BluetoothResources resources;
    if (!TakeConnection(state, generation, sender, "Could not read Bluetooth connection state.", resources)) return;
    if (resources.waiter) {
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->reducer.TakeChange(generation);
      }
      resources.waiter->Success(Status("error", "Could not read Bluetooth connection state."));
      resources.waiter.reset();
    }
    ReleaseResources(weak_executor.lock(), std::move(resources), false);
    return;
  }
  if (connection_state == AudioPlaybackConnectionState::Opened) {
    std::unique_ptr<MethodResult> waiter;
    {
      std::lock_guard<std::mutex> lock(state->mutex);
    if (!state->shutting_down && state->generation == generation &&
        state->connection && state->connection == sender) {
      if (state->reducer.Opened(generation)) {
        state->message = StateMessage(audioshare::SinkState::opened);
        waiter = std::move(state->waiter);
        if (waiter) state->reducer.TakeChange(generation);
      }
    }
    }
    if (waiter) waiter->Success(Status("opened", "The phone media route is connected."));
    return;
  }
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->shutting_down || state->generation != generation ||
        !state->connection || state->connection != sender ||
        !state->reducer.Closed(generation)) {
      // OpenAsync can succeed while Windows still reports Closed until the
      // phone selects this PC as its media output. Keep the sink enabled during
      // that initial waiting period; only release a connection that was Opened.
      return;
    }
  }
  BluetoothResources resources;
  if (!TakeConnection(state, generation, sender, "The phone media route disconnected.", resources))
    return;
  if (resources.waiter) {
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      state->reducer.TakeChange(generation);
    }
    resources.waiter->Success(Status("disconnected", "The phone media route disconnected."));
    resources.waiter.reset();
  }
  ReleaseResources(weak_executor.lock(), std::move(resources), false);
}
std::string StringArg(const EncodableValue* args, const std::string& key) {
  if (!args || !std::holds_alternative<EncodableMap>(*args)) return {};
  const auto& map = std::get<EncodableMap>(*args);
  const auto it = map.find(EncodableValue(key));
  return it != map.end() && std::holds_alternative<std::string>(it->second)
             ? std::get<std::string>(it->second) : std::string();
}
bool LaunchBluetoothSettings() {
  return reinterpret_cast<intptr_t>(ShellExecuteW(nullptr, L"open", L"ms-settings:bluetooth",
                                                   nullptr, nullptr, SW_SHOWNORMAL)) > 32;
}
}  // namespace

std::function<void()> RegisterExternalRouteChannel(flutter::BinaryMessenger* messenger) {
  const HRESULT ro_result = RoInitialize(RO_INIT_MULTITHREADED);
  const bool ro_initialized = SUCCEEDED(ro_result);
  auto channel = std::make_shared<flutter::MethodChannel<EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  auto state = std::make_shared<BluetoothState>();
  auto executor = std::make_shared<BackgroundExecutor>();
  channel->SetMethodCallHandler(
      [state, executor](const flutter::MethodCall<EncodableValue>& call,
                        std::unique_ptr<MethodResult> result) {
    const auto& method = call.method_name();
    if (method == "listBluetoothDevices") {
      const uint64_t generation = [&] { std::lock_guard<std::mutex> l(state->mutex); return state->generation; }();
      executor->Post([state, generation, result = std::move(result)]() mutable {
        try {
          auto operation = DeviceInformation::FindAllAsync(AudioPlaybackConnection::GetDeviceSelector());
          if (!SetPending(state, generation, operation.as<IAsyncInfo>())) {
            operation.Cancel(); result->Success(EncodableValue(EncodableList{})); return;
          }
          const auto devices = operation.get();
          ClearPending(state, generation);
          winrt::hstring connected;
          { std::lock_guard<std::mutex> l(state->mutex); connected = state->device_id; }
          EncodableList list;
          for (const auto& device : devices) list.emplace_back(EncodableMap{
            {EncodableValue("id"), EncodableValue(winrt::to_string(device.Id()))},
            {EncodableValue("name"), EncodableValue(winrt::to_string(device.Name()))},
            {EncodableValue("isSelectedSink"), EncodableValue(!connected.empty() && device.Id() == connected)}});
          result->Success(EncodableValue(list));
        } catch (const winrt::hresult_error& e) {
          result->Error("bluetooth_enumeration_failed", ErrorMessage("Could not enumerate Bluetooth audio devices", e));
        }
      }); return;
    }
    if (method == "startBluetoothSink") {
      const auto id_string = StringArg(call.arguments(), "deviceId");
      if (id_string.empty()) { result->Success(Status("error", "Missing Bluetooth device ID.")); return; }
      auto old = ResetState(state, "Bluetooth audio receiver is starting.");
      const uint64_t generation = old.generation;
      { std::lock_guard<std::mutex> lock(state->mutex); state->reducer.Begin(generation); }
      ReleaseResources(executor, std::move(old));
      executor->Post([state, executor, generation, id_string,
                      result = std::move(result)]() mutable {
        AudioPlaybackConnection connection{nullptr};
        winrt::event_token token{}; bool subscribed = false;
        try {
          if (!Current(state, generation)) { result->Success(Status("stopped", "Bluetooth startup was cancelled.")); return; }
          const auto id = winrt::to_hstring(id_string);
          connection = AudioPlaybackConnection::TryCreateFromId(id);
          if (!connection) { const std::string m = "Windows could not create a Bluetooth audio connection. Pair the phone first."; SetError(state, generation, m); result->Success(Status("error", m)); return; }
          {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (state->shutting_down || state->generation != generation) throw winrt::hresult_canceled();
            state->connection = connection; state->device_id = id;
          }
          token = connection.StateChanged(
              [weak_state = std::weak_ptr<BluetoothState>(state),
               weak_executor = std::weak_ptr<BackgroundExecutor>(executor),
               generation](auto&& sender, auto&&) {
                OnStateChanged(weak_state, weak_executor, generation, sender);
              });
          subscribed = true;
          {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (state->generation != generation || state->connection != connection) throw winrt::hresult_canceled();
            state->state_changed_token = token; state->has_state_changed_token = true;
          }
          // StateChanged may be reentrant; installation above makes the handler
          // recognize this connection. Sample immediately to close the boundary.
          OnStateChanged(std::weak_ptr<BluetoothState>(state),
                         std::weak_ptr<BackgroundExecutor>(executor), generation,
                         connection);
          auto start = connection.StartAsync();
          if (!SetPending(state, generation, start.as<IAsyncInfo>())) { start.Cancel(); throw winrt::hresult_canceled(); }
          start.get(); ClearPending(state, generation);
          auto open = connection.OpenAsync();
          if (!SetPending(state, generation, open.as<IAsyncInfo>())) { open.Cancel(); throw winrt::hresult_canceled(); }
          auto opened = open.get(); ClearPending(state, generation);
          if (opened.Status() != AudioPlaybackConnectionOpenResultStatus::Success)
            throw winrt::hresult_error(E_FAIL, L"AudioPlaybackConnection.OpenAsync failed");
          // Sample through the same production transition path used by events.
          // This both closes the subscription/startup boundary and releases the
          // connection if an observed Opened route has already become Closed.
          OnStateChanged(std::weak_ptr<BluetoothState>(state),
                         std::weak_ptr<BackgroundExecutor>(executor), generation,
                         connection);
          audioshare::SinkState initial;
          {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (state->shutting_down || state->generation != generation) throw winrt::hresult_canceled();
            if (state->reducer.state() == audioshare::SinkState::stopped) {
              state->reducer.Waiting(generation);
            }
            initial = state->reducer.TakeInitial(generation);
            state->message = StateMessage(initial);
          }
          subscribed = false;
          result->Success(Status(Mode(initial), StateMessage(initial)));
        } catch (const winrt::hresult_error& e) {
          bool current = Current(state, generation);
          std::optional<audioshare::SinkState> natural_terminal;
          if (current) {
            std::lock_guard<std::mutex> lock(state->mutex);
            const auto reduced = state->reducer.state();
            if (reduced == audioshare::SinkState::disconnected ||
                reduced == audioshare::SinkState::error) {
              natural_terminal = state->reducer.TakeInitial(generation);
            }
          }
          if (natural_terminal) {
            if (subscribed) {
              try {
                connection.StateChanged(token);
              } catch (...) {
              }
            }
            if (connection) {
              try {
                connection.Close();
              } catch (...) {
              }
            }
            result->Success(Status(Mode(*natural_terminal), StateMessage(*natural_terminal)));
            return;
          }
          const std::string message = current
                                          ? ErrorMessage(
                                                "Bluetooth audio connection failed", e)
                                          : "Bluetooth startup was cancelled.";
          BluetoothResources installed_resources;
          const bool installed =
              current && TakeConnection(state, generation, connection, message,
                                        installed_resources);
          if (installed) {
            subscribed = false;
            CloseResources(std::move(installed_resources));
          } else {
            if (subscribed)
              try {
                connection.StateChanged(token);
              } catch (...) {
              }
            if (connection)
              try {
                connection.Close();
              } catch (...) {
              }
            current = Current(state, generation);
            if (current) SetError(state, generation, message);
          }
          result->Success(Status(current ? "error" : "stopped", message));
        }
      }); return;
    }
    if (method == "waitBluetoothSinkStatusChange") {
      AudioPlaybackConnection connection{nullptr};
      uint64_t generation = 0;
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        connection = state->connection;
        generation = state->generation;
      }
      if (connection) {
        OnStateChanged(std::weak_ptr<BluetoothState>(state),
                       std::weak_ptr<BackgroundExecutor>(executor), generation,
                       connection);
      }
      std::unique_ptr<MethodResult> replaced;
      std::optional<audioshare::SinkState> cached;
      bool stopped = false;
      std::string stopped_message;
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->shutting_down || state->generation != generation) {
          stopped = true;
          stopped_message = state->message;
        } else {
          cached = state->reducer.TakeChange(generation);
          if (!cached && state->connection) {
            replaced = std::move(state->waiter); state->waiter = std::move(result);
          } else if (!cached) {
            stopped = true;
            stopped_message = state->message;
          }
        }
      }
      if (stopped) {
        result->Success(Status("stopped", stopped_message));
      } else if (cached) {
        result->Success(Status(Mode(*cached), StateMessage(*cached)));
      }
      if (replaced) {
        replaced->Success(Status("stopped", "Status waiter was replaced."));
      }
      return;
    }
    if (method == "stopBluetoothSink") {
      auto resources = ResetState(state, kStoppedMessage);
      ReleaseResources(executor, std::move(resources));
      result->Success(Status("stopped", kStoppedMessage)); return;
    }
    if (method == "openBluetoothSettings") {
      const bool launched = LaunchBluetoothSettings();
      result->Success(Status(launched ? "ready" : "error",
                             launched ? "Opened Windows Bluetooth settings." : "Could not open Windows Bluetooth settings."));
      return;
    }
    result->NotImplemented();
  });
  return [channel, state, executor, ro_initialized]() {
    channel->SetMethodCallHandler(nullptr);
    auto resources = ResetState(state, kStoppedMessage, true);
    ReleaseResources(executor, std::move(resources), false);
    executor->Stop();
    if (ro_initialized) RoUninitialize();
  };
}
