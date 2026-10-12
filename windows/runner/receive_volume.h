#pragma once

#include <windows.h>
#include <mmdeviceapi.h>
#include <audiopolicy.h>
#include <audioclient.h>
#include <winrt/base.h>

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

namespace audioshare {

// Used only on the route worker. Never changes endpoint or session master volume.
// Restore before releasing a route, because Windows persists channel volumes.
class ReceiveVolume {
 public:
  ~ReceiveVolume() { Restore(); }

  bool Locate(const std::wstring& phone_name) {
    winrt::com_ptr<IMMDeviceEnumerator> enumerator;
    winrt::check_hresult(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
        CLSCTX_ALL, IID_PPV_ARGS(enumerator.put())));
    winrt::com_ptr<IMMDeviceCollection> devices;
    winrt::check_hresult(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, devices.put()));
    const DWORD service_pid = AudioServicePid();
    if (!service_pid || phone_name.empty()) { Restore(); return false; }
    const auto suffix = L"(" + phone_name + L" A2DP SNK)";
    winrt::com_ptr<IChannelAudioVolume> found;
    winrt::com_ptr<IAudioSessionControl> found_control;
    std::wstring identity;
    int matches = 0;
    UINT device_count = 0;
    winrt::check_hresult(devices->GetCount(&device_count));
    for (UINT d = 0; d < device_count; ++d) {
      winrt::com_ptr<IMMDevice> device;
      winrt::check_hresult(devices->Item(d, device.put()));
      winrt::com_ptr<IAudioSessionManager2> manager;
      if (FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr, manager.put_void()))) continue;
      winrt::com_ptr<IAudioSessionEnumerator> sessions;
      winrt::check_hresult(manager->GetSessionEnumerator(sessions.put()));
      int count = 0;
      winrt::check_hresult(sessions->GetCount(&count));
      for (int i = 0; i < count; ++i) {
        winrt::com_ptr<IAudioSessionControl> control;
        winrt::check_hresult(sessions->GetSession(i, control.put()));
        AudioSessionState state{};
        winrt::check_hresult(control->GetState(&state));
        if (state != AudioSessionStateActive) continue;
        const auto detail = control.as<IAudioSessionControl2>();
        DWORD pid = 0;
        winrt::check_hresult(detail->GetProcessId(&pid));
        if (pid != service_pid) continue;
        LPWSTR raw = nullptr;
        winrt::check_hresult(control->GetDisplayName(&raw));
        const std::wstring name = raw ? raw : L"";
        CoTaskMemFree(raw);
        if (name.size() < suffix.size() ||
            name.compare(name.size() - suffix.size(), suffix.size(), suffix) != 0) continue;
        ++matches;
        found = control.try_as<IChannelAudioVolume>();
        found_control = control;
        raw = nullptr;
        winrt::check_hresult(detail->GetSessionInstanceIdentifier(&raw));
        identity = raw ? raw : L"";
        CoTaskMemFree(raw);
      }
    }
    // Names are only a conservative compatibility fallback, never match a
    // random svchost session or all sessions sharing the service process.
    if (matches != 1 || !found || identity.empty()) { Restore(); return false; }
    if (identity != identity_) {
      Restore();
      UINT count = 0;
      winrt::check_hresult(found->GetChannelCount(&count));
      if (count == 0 || count > 32) return false;
      std::vector<float> original(count);
      winrt::check_hresult(found->GetAllVolumes(count, original.data()));
      channels_ = std::move(found);
      control_ = std::move(found_control);
      identity_ = identity;
      original_ = original;
      last_ = original;
      value_ = 100;
    }
    return Validate();
  }

  // Keep the exact session instance while dragging, without device enumeration.
  // A disappeared/inactive session must be explicitly refreshed before rebinding.
  bool Validate() {
    AudioSessionState state{};
    if (!channels_ || !control_ || FAILED(control_->GetState(&state)) ||
        state != AudioSessionStateActive) {
      Restore();
      return false;
    }
    // External changes become the new baseline; don't overwrite other controls.
    std::vector<float> actual(original_.size());
    winrt::check_hresult(channels_->GetAllVolumes(static_cast<UINT>(actual.size()), actual.data()));
    if (!Equal(actual, last_)) {
      original_ = actual;
      last_ = actual;
      value_ = 100;
      changed_ = false;
    }
    return true;
  }

  void Set(int percent) {
    if (!channels_ || percent < 0 || percent > 100) throw winrt::hresult_invalid_argument();
    auto values = original_;
    for (auto& value : values) value *= static_cast<float>(percent) / 100.0f;
    winrt::check_hresult(channels_->SetAllVolumes(static_cast<UINT>(values.size()), values.data(), nullptr));
    last_ = values;
    value_ = percent;
    changed_ = percent != 100;
  }
  int value() const { return value_; }

  void Restore() noexcept {
    if (channels_ && changed_) {
      std::vector<float> actual(last_.size());
      if (SUCCEEDED(channels_->GetAllVolumes(static_cast<UINT>(actual.size()), actual.data())) && Equal(actual, last_))
        channels_->SetAllVolumes(static_cast<UINT>(original_.size()), original_.data(), nullptr);
    }
    channels_ = nullptr;
    control_ = nullptr;
    identity_.clear();
    original_.clear();
    last_.clear();
    changed_ = false;
    value_ = 100;
  }

 private:
  static bool Equal(const std::vector<float>& a, const std::vector<float>& b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) if (std::abs(a[i] - b[i]) > 0.0001f) return false;
    return true;
  }
  static DWORD AudioServicePid() {
    const auto manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (!manager) return 0;
    const auto service = OpenServiceW(manager, L"Audiosrv", SERVICE_QUERY_STATUS);
    CloseServiceHandle(manager);
    if (!service) return 0;
    SERVICE_STATUS_PROCESS status{};
    DWORD bytes = 0;
    const bool ok = QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO,
        reinterpret_cast<LPBYTE>(&status), sizeof(status), &bytes) != FALSE;
    CloseServiceHandle(service);
    return ok && status.dwCurrentState == SERVICE_RUNNING ? status.dwProcessId : 0;
  }
  winrt::com_ptr<IChannelAudioVolume> channels_;
  winrt::com_ptr<IAudioSessionControl> control_;
  std::wstring identity_;
  std::vector<float> original_, last_;
  int value_ = 100;
  bool changed_ = false;
};
}  // namespace audioshare
