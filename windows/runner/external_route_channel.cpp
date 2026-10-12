#include "external_route_channel.h"
#include "bluetooth_status_server.h"
#include "sink_state_machine.h"
#include "sink_open_retry.h"
#include "connection_trace.h"
#include "receive_volume.h"

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
#include <chrono>
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
using winrt::Windows::Devices::Enumeration::DeviceInformationKind;
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
  std::optional<uint64_t> target_address;
  uint64_t generation = 0;
  audioshare::SinkStateMachine reducer;
  bool shutting_down = false;
  std::shared_ptr<audioshare::ReceiveVolume> volume = std::make_shared<audioshare::ReceiveVolume>();
};
struct BluetoothResources {
  AudioPlaybackConnection connection{nullptr};
  winrt::event_token token{};
  bool has_token = false;
  IAsyncInfo pending_operation{nullptr};
  std::unique_ptr<MethodResult> waiter;
  uint64_t generation = 0;
  std::shared_ptr<audioshare::ReceiveVolume> volume;
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
  out.volume = state->volume;
  state->connection = nullptr;
  state->has_state_changed_token = false;
  state->device_id.clear();
  state->pending_operation = nullptr;
  state->target_address.reset();
  state->message = message;
  state->reducer.Stop();
  state->shutting_down = state->shutting_down || shutdown;
  return out;
}
void CloseResources(BluetoothResources resources, bool complete_waiter = true) {
  if (resources.volume) resources.volume->Restore();
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
template <typename T>
bool WaitForAddressOperation(const std::shared_ptr<BluetoothState>& state,
                             uint64_t generation, const T& operation,
                             std::chrono::steady_clock::time_point deadline,
                             std::string& diagnostic) {
  if (!SetPending(state, generation, operation.template as<IAsyncInfo>())) {
    operation.Cancel();
    throw winrt::hresult_canceled();
  }
  const auto remaining = deadline - std::chrono::steady_clock::now();
  const winrt::Windows::Foundation::TimeSpan timeout{
      std::chrono::duration_cast<std::chrono::duration<int64_t, std::ratio<1, 10000000>>>(
          remaining).count()};
  if (remaining <= std::chrono::steady_clock::duration::zero() ||
      operation.wait_for(timeout) !=
          winrt::Windows::Foundation::AsyncStatus::Completed) {
    operation.Cancel();
    ClearPending(state, generation);
    if (!Current(state, generation)) throw winrt::hresult_canceled();
    diagnostic = "device association lookup timed out";
    return false;
  }
  ClearPending(state, generation);
  if (!Current(state, generation)) throw winrt::hresult_canceled();
  return true;
}
std::optional<uint64_t> ParseBluetoothAddress(const winrt::hstring& value) {
  if (value.size() != 12 && value.size() != 17) return std::nullopt;
  uint64_t address = 0;
  for (winrt::hstring::size_type index = 0; index < value.size(); ++index) {
    const wchar_t character = value[index];
    if (value.size() == 17 && index % 3 == 2) {
      if (character != L':') return std::nullopt;
      continue;
    }
    uint64_t digit;
    if (character >= L'0' && character <= L'9') digit = character - L'0';
    else if (character >= L'a' && character <= L'f') digit = character - L'a' + 10;
    else if (character >= L'A' && character <= L'F') digit = character - L'A' + 10;
    else return std::nullopt;
    address = (address << 4) | digit;
  }
  return address;
}
std::optional<winrt::hstring> StringProperty(
    const DeviceInformation& device, const wchar_t* name) {
  if (!device) return std::nullopt;
  const auto value = device.Properties().TryLookup(name);
  if (!value) return std::nullopt;
  try { return winrt::unbox_value<winrt::hstring>(value); }
  catch (...) { return std::nullopt; }
}
void LogAddressDiagnostic(const std::string& reason) {
  const std::string message =
      "AudioShare: Bluetooth target address unavailable: " + reason + "\n";
  OutputDebugStringA(message.c_str());
}
void SetError(const std::shared_ptr<BluetoothState>& state, uint64_t generation,
              const std::string& message) {
  std::lock_guard<std::mutex> lock(state->mutex);
  if (!state->shutting_down && state->generation == generation) {
    state->pending_operation = nullptr;
    state->message = message;
    state->reducer.Error(generation);
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
  resources.volume = state->volume;
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
  auto state = weak_state.lock();
  if (!state) return;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    // StartAsync/OpenAsync can temporarily alternate Opened/Closed while the
    // driver negotiates the first route. Do not tear down the connection from
    // those provisional events. Startup samples State after OpenAsync settles.
    if (state->shutting_down || state->generation != generation ||
        state->reducer.startup_pending() || !state->connection || state->connection != sender)
      return;
  }
  AudioPlaybackConnectionState connection_state =
      AudioPlaybackConnectionState::Closed;
  bool state_read_failed = false;
  try {
    connection_state = sender.State();
  } catch (...) {
    state_read_failed = true;
  }
  if (state_read_failed) {
    audioshare::TraceConnection(generation, "state_read_failed");
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (state->generation != generation || state->connection != sender ||
          !state->reducer.Error(generation)) return;
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
          audioshare::TraceConnection(generation, "route_opened");
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
  audioshare::TraceConnection(generation, "route_disconnected");
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
  auto status_server = std::make_shared<audioshare::BluetoothStatusServer>(
      [weak_state = std::weak_ptr<BluetoothState>(state)](uint64_t peer) {
        audioshare::BluetoothStatusSnapshot snapshot{"stopped", "unknown"};
        const auto locked = weak_state.lock();
        if (!locked) return snapshot;
        std::lock_guard<std::mutex> lock(locked->mutex);
        snapshot.mode = locked->reducer.startup_pending() ? "starting" : Mode(locked->reducer.state());
        if (locked->target_address)
          snapshot.target = *locked->target_address == peer ? "thisPhone" : "otherPhone";
        return snapshot;
      });
  status_server->Start();
  channel->SetMethodCallHandler(
      [state, executor, status_server](const flutter::MethodCall<EncodableValue>& call,
                        std::unique_ptr<MethodResult> result) {
    const auto& method = call.method_name();
    if (method == "getReceiveVolume" || method == "setReceiveVolume") {
      int value = -1;
      if (method == "setReceiveVolume") {
        const auto* args = call.arguments();
        if (args && std::holds_alternative<EncodableMap>(*args)) {
          const auto& map = std::get<EncodableMap>(*args);
          const auto it = map.find(EncodableValue("value"));
          if (it != map.end() && std::holds_alternative<int32_t>(it->second))
            value = std::get<int32_t>(it->second);
        }
        if (value < 0 || value > 100) {
          result->Error("invalid_volume", "音量必须在 0–100 之间。"); return;
        }
      }
      uint64_t generation;
      winrt::hstring device_id;
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        generation = state->generation;
        device_id = state->device_id;
      }
      executor->Post([state, generation, device_id, value, result = std::move(result)]() mutable {
        auto reply = [&](bool available, const char* message) {
          result->Success(EncodableValue(EncodableMap{
            {EncodableValue("available"), EncodableValue(available)},
            {EncodableValue("current"), EncodableValue(state->volume->value())},
            {EncodableValue("max"), EncodableValue(100)},
            {EncodableValue("fixed"), EncodableValue(!available)},
            {EncodableValue("message"), EncodableValue(message)}}));
        };
        try {
          if (device_id.empty() || !Current(state, generation)) {
            reply(false, "请先连接手机并开始播放，再刷新音量。"); return;
          }
          if (value < 0) {
            auto operation = DeviceInformation::FindAllAsync(AudioPlaybackConnection::GetDeviceSelector());
            if (operation.wait_for(std::chrono::seconds(3)) != winrt::Windows::Foundation::AsyncStatus::Completed) {
              operation.Cancel(); reply(false, "设备查询超时，请刷新重试。"); return;
            }
            const auto devices = operation.get();
            std::wstring name;
            for (const auto& device : devices) if (device.Id() == device_id) name = device.Name().c_str();
            int names = 0;
            for (const auto& device : devices) if (device.Name() == name) ++names;
            if (name.empty() || names != 1 || !Current(state, generation)) {
              reply(false, "无法唯一识别手机的接收会话。"); return;
            }
            if (!state->volume->Locate(name)) {
              reply(false, "未找到独立接收声道。请播放手机音频后刷新。"); return;
            }
          } else if (!state->volume->Validate()) {
            reply(false, "接收声道已变化，请刷新音量。"); return;
          }
          {
            // Stop/device changes cannot slip between validating and writing.
            std::lock_guard<std::mutex> lock(state->mutex);
            if (state->shutting_down || state->generation != generation ||
                state->device_id != device_id || state->reducer.state() != audioshare::SinkState::opened) {
              reply(false, "连接已变化，请重新连接后刷新。"); return;
            }
            if (value >= 0) state->volume->Set(value);
          }
          reply(true, "仅调节电脑接收声道；100% 为原始音量。");
        } catch (...) {
          reply(false, "接收声道暂不可用，请刷新重试。");
        }
      });
      return;
    }
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
      audioshare::TraceConnection(generation, "user_start");
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->reducer.Begin(generation, true);
      }
      ReleaseResources(executor, std::move(old));
      executor->Post([state, executor, generation, id_string,
                      result = std::move(result)]() mutable {
        AudioPlaybackConnection connection{nullptr};
        winrt::event_token token{};
        bool subscribed = false;
        bool ownership_transferred = false;
        try {
          if (!Current(state, generation)) { result->Success(Status("stopped", "Bluetooth startup was cancelled.")); return; }
          const auto id = winrt::to_hstring(id_string);
          // AudioPlaybackConnection IDs identify device interfaces, not
          // BluetoothDevice instances. Walk the explicit DeviceInformation
          // association properties without opening the remote device.
          try {
            constexpr wchar_t kAddress[] = L"System.DeviceInterface.Bluetooth.DeviceAddress";
            constexpr wchar_t kAepAddress[] = L"System.Devices.Aep.DeviceAddress";
            constexpr wchar_t kInstanceId[] = L"System.Devices.DeviceInstanceId";
            constexpr wchar_t kAepId[] = L"System.Devices.Aep.AepId";
            constexpr wchar_t kProtocolId[] = L"System.Devices.Aep.ProtocolId";
            const winrt::guid kBluetoothClassic{
                0xe0cbf06c, 0xcd8b, 0x4647, {0xbb, 0x8a, 0x26, 0x3b, 0x43, 0xf0, 0xf9, 0x74}};
            const auto deadline = std::chrono::steady_clock::now() +
                                  std::chrono::seconds(3);
            std::string diagnostic;
            std::optional<uint64_t> address;
            auto interface_operation = DeviceInformation::CreateFromIdAsync(
                id, {kAddress, kInstanceId}, DeviceInformationKind::DeviceInterface);
            if (WaitForAddressOperation(state, generation, interface_operation,
                                        deadline, diagnostic)) {
              const auto interface_info = interface_operation.get();
              if (const auto direct = StringProperty(interface_info, kAddress))
                address = ParseBluetoothAddress(*direct);
              if (!address) {
                const auto instance_id = StringProperty(interface_info, kInstanceId);
                if (!instance_id || instance_id->empty()) {
                  diagnostic = "interface has no device-instance association";
                } else {
                  auto device_operation = DeviceInformation::CreateFromIdAsync(
                      *instance_id, {kAepId}, DeviceInformationKind::Device);
                  if (WaitForAddressOperation(state, generation, device_operation,
                                              deadline, diagnostic)) {
                    const auto device_info = device_operation.get();
                    const auto aep_id = StringProperty(device_info, kAepId);
                    if (!aep_id || aep_id->empty()) {
                      diagnostic = "device has no association-endpoint ID";
                    } else {
                      auto aep_operation = DeviceInformation::CreateFromIdAsync(
                          *aep_id, {kProtocolId, kAepAddress},
                          DeviceInformationKind::AssociationEndpoint);
                      if (WaitForAddressOperation(state, generation, aep_operation,
                                                  deadline, diagnostic)) {
                        const auto aep = aep_operation.get();
                        if (!aep) throw winrt::hresult_error(E_FAIL, L"Association endpoint disappeared");
                        const auto protocol_value = aep.Properties().TryLookup(kProtocolId);
                        bool classic = false;
                        if (protocol_value) try {
                          classic = winrt::unbox_value<winrt::guid>(protocol_value) ==
                                    kBluetoothClassic;
                        } catch (...) {}
                        if (!classic) {
                          diagnostic = "association endpoint is not Bluetooth Classic";
                        } else if (const auto associated = StringProperty(aep, kAepAddress)) {
                          address = ParseBluetoothAddress(*associated);
                          if (!address) diagnostic = "association address is not a 48-bit string";
                        } else {
                          diagnostic = "association endpoint has no address";
                        }
                      }
                    }
                  }
                }
              }
            }
            if (address) {
              std::lock_guard<std::mutex> lock(state->mutex);
              if (!state->shutting_down && state->generation == generation)
                state->target_address = *address;
            } else {
              if (diagnostic.empty()) diagnostic = "interface address is not a 48-bit string";
              LogAddressDiagnostic(diagnostic);
            }
          } catch (const winrt::hresult_error& e) {
            // Address failure only makes target unknown; A2DP startup continues.
            ClearPending(state, generation);
            if (!Current(state, generation)) throw;
            LogAddressDiagnostic("DeviceInformation lookup failed (HRESULT " +
                                 std::to_string(static_cast<uint32_t>(e.code())) + ")");
          }
          if (!Current(state, generation)) throw winrt::hresult_canceled();
          using audioshare::SinkOpenOutcome;
          std::string open_diagnostic;
          const auto outcome = audioshare::RecoverSinkSessionOnce([&] {
            audioshare::TraceConnection(generation, "create_connection");
            connection = AudioPlaybackConnection::TryCreateFromId(id);
            if (!connection) throw winrt::hresult_error(E_FAIL, L"Windows could not create a Bluetooth audio connection. Pair the phone first.");
            token = connection.StateChanged(
                [weak_state = std::weak_ptr<BluetoothState>(state),
                 weak_executor = std::weak_ptr<BackgroundExecutor>(executor),
                 generation](auto&& sender, auto&&) {
                  OnStateChanged(weak_state, weak_executor, generation, sender);
                });
            subscribed = true;
            {
              std::lock_guard<std::mutex> lock(state->mutex);
              if (state->shutting_down || state->generation != generation)
                throw winrt::hresult_canceled();
              state->connection = connection;
              state->device_id = id;
              state->state_changed_token = token;
              state->has_state_changed_token = true;
              ownership_transferred = true;
            }
            // StateChanged may be reentrant; installation above makes the handler
            // recognize this connection. Sample immediately to close the boundary.
            OnStateChanged(std::weak_ptr<BluetoothState>(state),
                           std::weak_ptr<BackgroundExecutor>(executor), generation,
                           connection);
            auto start = connection.StartAsync();
            audioshare::TraceConnection(generation, "start_async");
            if (!SetPending(state, generation, start.as<IAsyncInfo>())) { start.Cancel(); throw winrt::hresult_canceled(); }
            start.get(); ClearPending(state, generation);
            audioshare::TraceConnection(generation, "start_complete");
            // A newly enabled A2DP service can fail its first open while SDP and
            // the phone's route catch up. Keep the started sink alive and retry
            // transient failures; an explicit stop cancels both open and backoff.
            return audioshare::OpenSinkWithRetry([&] {
              try {
                auto open = connection.OpenAsync();
                audioshare::TraceConnection(generation, "open_async");
                if (!SetPending(state, generation, open.as<IAsyncInfo>())) {
                  open.Cancel(); return SinkOpenOutcome::cancelled;
                }
                const auto opened = open.get();
                ClearPending(state, generation);
                audioshare::TraceConnection(generation, "open_result=" +
                    std::to_string(static_cast<int>(opened.Status())) + " hresult=" +
                    std::to_string(static_cast<int32_t>(opened.ExtendedError())));
                // Denial must win over a stale or provisional Opened state.
                if (opened.Status() == AudioPlaybackConnectionOpenResultStatus::DeniedBySystem)
                  return SinkOpenOutcome::denied;
                // A provisional Opened event cannot override a failed result.
                if (opened.Status() == AudioPlaybackConnectionOpenResultStatus::Success)
                  return SinkOpenOutcome::opened;
                open_diagnostic = "OpenAsync status=" +
                    std::to_string(static_cast<int>(opened.Status())) +
                    ", HRESULT=" + std::to_string(static_cast<int32_t>(opened.ExtendedError()));
                return SinkOpenOutcome::transient_failure;
              } catch (const winrt::hresult_error& error) {
                ClearPending(state, generation);
                if (!Current(state, generation) || error.code() == E_ABORT ||
                    error.code() == HRESULT_FROM_WIN32(ERROR_CANCELLED))
                  return SinkOpenOutcome::cancelled;
                if (error.code() == E_ACCESSDENIED) return SinkOpenOutcome::denied;
                // Invalid arguments, disposed objects, and other programming
                // errors must not be disguised as transient driver negotiation.
                if (error.code() != E_FAIL &&
                    error.code() != HRESULT_FROM_WIN32(ERROR_TIMEOUT) &&
                    error.code() != HRESULT_FROM_WIN32(ERROR_NOT_READY)) throw;
                open_diagnostic = ErrorMessage("OpenAsync", error);
                return SinkOpenOutcome::transient_failure;
              }
            }, [&] { return Current(state, generation); }, [](auto delay) {
              std::this_thread::sleep_for(delay);
            });
          }, [&](SinkOpenOutcome previous) {
            const bool priming = previous == SinkOpenOutcome::opened;
            audioshare::TraceConnection(generation, priming
                ? "prime_first_connection" : "rebuild_failed_connection");
            if (priming) {
              // Let the driver finish creating its first render graph before
              // the stop/start boundary. No meter/volume level is used as a
              // playback test: a valid silent/paused stream is not an error.
              for (int tick = 0; tick < 15; ++tick) {
                if (!Current(state, generation)) throw winrt::hresult_canceled();
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
              }
            }
            // Detach before Close so old events cannot terminate the new
            // connection. Startup remains pending throughout the warm-up.
            BluetoothResources failed;
            if (!TakeConnection(state, generation, connection,
                                "Preparing Bluetooth receiver startup.", failed))
              throw winrt::hresult_canceled();
            CloseResources(std::move(failed));
            connection = nullptr;
            subscribed = false;
            ownership_transferred = false;
            for (int tick = 0; tick < 15; ++tick) {
              if (!Current(state, generation)) throw winrt::hresult_canceled();
              std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
          }, [&] { return Current(state, generation); }, true);
          if (outcome == SinkOpenOutcome::cancelled) throw winrt::hresult_canceled();
          if (outcome == SinkOpenOutcome::denied) throw winrt::hresult_access_denied();
          if (outcome != SinkOpenOutcome::opened)
            throw winrt::hresult_error(E_FAIL, winrt::to_hstring(
                "Bluetooth media route could not open after rebuilding the receiver. " + open_diagnostic));
          {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (state->shutting_down || state->generation != generation)
              throw winrt::hresult_canceled();
            state->reducer.FinishStartup(generation);
          }
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
          result->Success(Status(Mode(initial), StateMessage(initial)));
          audioshare::TraceConnection(generation, std::string("startup_finished=") + Mode(initial));
        } catch (const winrt::hresult_error& e) {
          audioshare::TraceConnection(generation, "startup_exception=" +
              std::to_string(static_cast<int32_t>(e.code())));
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
            if (!ownership_transferred && subscribed) {
              try {
                connection.StateChanged(token);
              } catch (...) {
              }
            }
            if (!ownership_transferred && connection) {
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
            ownership_transferred = false;
            CloseResources(std::move(installed_resources));
            SetError(state, generation, message);
          } else {
            if (!ownership_transferred && subscribed)
              try {
                connection.StateChanged(token);
              } catch (...) {
              }
            if (!ownership_transferred && connection)
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
      audioshare::TraceConnection(resources.generation, "user_stop");
      ReleaseResources(executor, std::move(resources));
      result->Success(Status("stopped", kStoppedMessage)); return;
    }
    if (method == "openBluetoothSettings") {
      const bool launched = LaunchBluetoothSettings();
      if (launched) {
        result->Success();
      } else {
        result->Error("settings_failed", "Could not open Windows Bluetooth settings.");
      }
      return;
    }
    if (method == "getStatusServiceInfo") {
      const auto info = status_server->GetInfo();
      result->Success(EncodableValue(EncodableMap{
          {EncodableValue("available"), EncodableValue(info.available)},
          {EncodableValue("message"), EncodableValue(info.message)}}));
      return;
    }
    result->NotImplemented();
  });
  return [channel, state, executor, status_server, ro_initialized]() {
    channel->SetMethodCallHandler(nullptr);
    status_server->Stop();
    auto resources = ResetState(state, kStoppedMessage, true);
    ReleaseResources(executor, std::move(resources), false);
    executor->Stop();
    if (ro_initialized) RoUninitialize();
  };
}
