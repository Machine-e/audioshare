#include "external_route_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <endpointvolume.h>
#include <mmdeviceapi.h>
#include <roapi.h>
#include <shellapi.h>
#include <windows.h>

#include <memory>
#include <filesystem>
#include <string>
#include <variant>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kChannelName[] = "com.machinee.audioshare/external_route";
HANDLE g_bluetooth_process = nullptr;
std::wstring g_bluetooth_script_path;

EncodableValue Status(const std::string& mode, const std::string& message) {
  return EncodableValue(EncodableMap{
      {EncodableValue("mode"), EncodableValue(mode)},
      {EncodableValue("message"), EncodableValue(message)},
  });
}

void StopBluetoothProcess() {
  if (g_bluetooth_process != nullptr) {
    TerminateProcess(g_bluetooth_process, 0);
    CloseHandle(g_bluetooth_process);
    g_bluetooth_process = nullptr;
  }
  if (!g_bluetooth_script_path.empty()) {
    DeleteFileW(g_bluetooth_script_path.c_str());
    g_bluetooth_script_path.clear();
  }
}

std::wstring Utf16FromUtf8(const std::string& input) {
  if (input.empty()) {
    return std::wstring();
  }
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
                                 static_cast<int>(input.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring output(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
                      static_cast<int>(input.size()), output.data(), size);
  return output;
}

bool LaunchUri(const std::wstring& uri) {
  HINSTANCE result =
      ShellExecuteW(nullptr, L"open", uri.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
  return reinterpret_cast<intptr_t>(result) > 32;
}

EncodableValue RunPowerShellJson(const std::wstring& script) {
  wchar_t temp_path[MAX_PATH];
  if (GetTempPathW(MAX_PATH, temp_path) == 0) {
    return Status("error", "Could not get temporary directory.");
  }

  wchar_t temp_file[MAX_PATH];
  if (GetTempFileNameW(temp_path, L"asr", 0, temp_file) == 0) {
    return Status("error", "Could not create temporary script.");
  }

  HANDLE file = CreateFileW(temp_file, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_TEMPORARY, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    DeleteFileW(temp_file);
    return Status("error", "Could not write temporary script.");
  }

  const wchar_t bom = 0xFEFF;
  DWORD written = 0;
  WriteFile(file, &bom, sizeof(bom), &written, nullptr);
  WriteFile(file, script.data(), static_cast<DWORD>(script.size() * sizeof(wchar_t)),
            &written, nullptr);
  CloseHandle(file);

  std::wstring command = L"powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"";
  command += temp_file;
  command += L"\"";

  wchar_t output_file[MAX_PATH];
  GetTempFileNameW(temp_path, L"aso", 0, output_file);
  command += L" > \"";
  command += output_file;
  command += L"\"";

  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process = {};
  std::wstring mutable_command = command;
  BOOL created = CreateProcessW(nullptr, mutable_command.data(), nullptr, nullptr,
                                FALSE, CREATE_NO_WINDOW, nullptr, nullptr,
                                &startup, &process);
  if (!created) {
    DeleteFileW(temp_file);
    DeleteFileW(output_file);
    return Status("error", "Could not start PowerShell helper.");
  }

  WaitForSingleObject(process.hProcess, 10000);
  DWORD exit_code = 1;
  GetExitCodeProcess(process.hProcess, &exit_code);
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  DeleteFileW(temp_file);

  HANDLE out = CreateFileW(output_file, GENERIC_READ, FILE_SHARE_READ, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (out == INVALID_HANDLE_VALUE) {
    DeleteFileW(output_file);
    return Status("error", "Could not read PowerShell helper output.");
  }
  DWORD size = GetFileSize(out, nullptr);
  std::string bytes(size, '\0');
  ReadFile(out, bytes.data(), size, &written, nullptr);
  CloseHandle(out);
  DeleteFileW(output_file);

  if (exit_code != 0) {
    return Status("error", "PowerShell helper failed.");
  }
  return EncodableValue(bytes);
}

EncodableValue RunExecutableJson(const std::wstring& executable,
                                 const std::wstring& arguments,
                                 DWORD timeout_ms) {
  wchar_t temp_path[MAX_PATH];
  if (GetTempPathW(MAX_PATH, temp_path) == 0) {
    return Status("error", "Could not get temporary directory.");
  }

  wchar_t output_file[MAX_PATH];
  if (GetTempFileNameW(temp_path, L"asa", 0, output_file) == 0) {
    return Status("error", "Could not create helper output file.");
  }

  std::wstring command = L"\"";
  command += executable;
  command += L"\" ";
  command += arguments;
  command += L" --output \"";
  command += output_file;
  command += L"\"";

  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process = {};
  std::wstring mutable_command = command;
  BOOL created = CreateProcessW(nullptr, mutable_command.data(), nullptr, nullptr,
                                FALSE, CREATE_NO_WINDOW, nullptr, nullptr,
                                &startup, &process);
  if (!created) {
    DeleteFileW(output_file);
    return Status("error", "Could not start Auracast scanner helper.");
  }

  const DWORD wait_result = WaitForSingleObject(process.hProcess, timeout_ms);
  if (wait_result == WAIT_TIMEOUT) {
    TerminateProcess(process.hProcess, 1);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    DeleteFileW(output_file);
    return Status("error", "Auracast scanner helper timed out.");
  }

  DWORD exit_code = 1;
  GetExitCodeProcess(process.hProcess, &exit_code);
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);

  HANDLE out = CreateFileW(output_file, GENERIC_READ, FILE_SHARE_READ, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (out == INVALID_HANDLE_VALUE) {
    DeleteFileW(output_file);
    return Status("error", "Could not read Auracast scanner output.");
  }
  const DWORD size = GetFileSize(out, nullptr);
  std::string bytes(size, '\0');
  DWORD read = 0;
  ReadFile(out, bytes.data(), size, &read, nullptr);
  CloseHandle(out);
  DeleteFileW(output_file);

  if (exit_code != 0) {
    return Status("error", "Auracast scanner helper failed.");
  }
  return EncodableValue(bytes);
}

EncodableValue StartPersistentBluetoothSink(const std::wstring& device_id) {
  StopBluetoothProcess();

  wchar_t temp_path[MAX_PATH];
  if (GetTempPathW(MAX_PATH, temp_path) == 0) {
    return Status("error", "Could not get temporary directory.");
  }

  wchar_t script_file[MAX_PATH];
  wchar_t ready_file[MAX_PATH];
  if (GetTempFileNameW(temp_path, L"asb", 0, script_file) == 0 ||
      GetTempFileNameW(temp_path, L"asr", 0, ready_file) == 0) {
    return Status("error", "Could not create Bluetooth helper temp files.");
  }
  DeleteFileW(ready_file);

  std::wstring script =
      LR"ps(
$ErrorActionPreference = 'Stop'
$deviceId = @'
)ps";
  script += device_id;
  script += LR"ps(
'@
$readyPath = @'
)ps";
  script += ready_file;
  script += LR"ps(
'@
try {
  $connection = [Windows.Media.Audio.AudioPlaybackConnection, Windows.Media, ContentType=WindowsRuntime]::TryCreateFromId($deviceId)
  if ($null -eq $connection) {
    [IO.File]::WriteAllText($readyPath, ([pscustomobject]@{ mode = 'error'; message = 'Could not create AudioPlaybackConnection for this device. Pair the phone first and confirm it supports remote audio playback.' } | ConvertTo-Json -Compress), [Text.Encoding]::UTF8)
    Start-Sleep -Seconds 2
    exit
  }
  try {
    $startResult = $connection.Start()
    if ($startResult -is [bool] -and -not $startResult) {
      throw 'AudioPlaybackConnection.Start returned false.'
    }
  } catch {
    throw ('Could not start AudioPlaybackConnection: ' + $_.Exception.Message)
  }
  try {
    $openResult = $connection.Open()
  } catch {
    throw ('Could not open AudioPlaybackConnection: ' + $_.Exception.Message)
  }
  if ($null -eq $openResult) {
    throw 'AudioPlaybackConnection.Open did not return an OpenResult.'
  }
  if ([string]$openResult.Status -ne 'Success') {
    throw ('AudioPlaybackConnection.Open returned status: ' + [string]$openResult.Status)
  }
  [IO.File]::WriteAllText($readyPath, ([pscustomobject]@{ mode = 'enabled'; message = 'AudioPlaybackConnection is enabled and open. Select this PC from Android media output.' } | ConvertTo-Json -Compress), [Text.Encoding]::UTF8)
  while ($true) { Start-Sleep -Seconds 3600 }
} catch {
  [IO.File]::WriteAllText($readyPath, ([pscustomobject]@{ mode = 'error'; message = ('Bluetooth audio receiver failed: ' + $_.Exception.Message) } | ConvertTo-Json -Compress), [Text.Encoding]::UTF8)
  Start-Sleep -Seconds 2
}
)ps";

  HANDLE file = CreateFileW(script_file, GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    DeleteFileW(script_file);
    return Status("error", "Could not write Bluetooth helper script.");
  }
  const wchar_t bom = 0xFEFF;
  DWORD written = 0;
  WriteFile(file, &bom, sizeof(bom), &written, nullptr);
  WriteFile(file, script.data(), static_cast<DWORD>(script.size() * sizeof(wchar_t)),
            &written, nullptr);
  CloseHandle(file);

  std::wstring command =
      L"powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"";
  command += script_file;
  command += L"\"";

  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process = {};
  std::wstring mutable_command = command;
  BOOL created = CreateProcessW(nullptr, mutable_command.data(), nullptr, nullptr,
                                FALSE, CREATE_NO_WINDOW, nullptr, nullptr,
                                &startup, &process);
  if (!created) {
    DeleteFileW(script_file);
    return Status("error", "Could not start Bluetooth AudioPlaybackConnection helper.");
  }
  CloseHandle(process.hThread);

  std::string bytes;
  for (int attempt = 0; attempt < 100; ++attempt) {
    HANDLE ready = CreateFileW(ready_file, GENERIC_READ, FILE_SHARE_READ, nullptr,
                               OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (ready != INVALID_HANDLE_VALUE) {
      DWORD size = GetFileSize(ready, nullptr);
      bytes.resize(size);
      DWORD read = 0;
      ReadFile(ready, bytes.data(), size, &read, nullptr);
      CloseHandle(ready);
      DeleteFileW(ready_file);
      break;
    }
    DWORD exit_code = STILL_ACTIVE;
    GetExitCodeProcess(process.hProcess, &exit_code);
    if (exit_code != STILL_ACTIVE) {
      break;
    }
    Sleep(100);
  }

  if (bytes.empty()) {
    TerminateProcess(process.hProcess, 0);
    CloseHandle(process.hProcess);
    DeleteFileW(script_file);
    DeleteFileW(ready_file);
    return Status("error", "Bluetooth helper did not return startup status.");
  }

  if (bytes.find("\"mode\":\"enabled\"") != std::string::npos) {
    g_bluetooth_process = process.hProcess;
    g_bluetooth_script_path = script_file;
  } else {
    TerminateProcess(process.hProcess, 0);
    CloseHandle(process.hProcess);
    DeleteFileW(script_file);
  }

  return EncodableValue(bytes);
}

std::string StringArg(const EncodableValue* args, const std::string& key) {
  if (!args || !std::holds_alternative<EncodableMap>(*args)) {
    return std::string();
  }
  const auto& map = std::get<EncodableMap>(*args);
  auto it = map.find(EncodableValue(key));
  if (it == map.end() || !std::holds_alternative<std::string>(it->second)) {
    return std::string();
  }
  return std::get<std::string>(it->second);
}

int IntArg(const EncodableValue* args, const std::string& key, int fallback) {
  if (!args || !std::holds_alternative<EncodableMap>(*args)) {
    return fallback;
  }
  const auto& map = std::get<EncodableMap>(*args);
  auto it = map.find(EncodableValue(key));
  if (it == map.end()) {
    return fallback;
  }
  if (std::holds_alternative<int>(it->second)) {
    return std::get<int>(it->second);
  }
  if (std::holds_alternative<int64_t>(it->second)) {
    return static_cast<int>(std::get<int64_t>(it->second));
  }
  return fallback;
}

std::wstring CurrentExecutableDirectory() {
  wchar_t path[MAX_PATH];
  const DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return std::wstring();
  }
  return std::filesystem::path(path).parent_path().wstring();
}

bool IsDefaultOutputActive() {
  HRESULT init_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool should_uninitialize = SUCCEEDED(init_result);
  if (FAILED(init_result) && init_result != RPC_E_CHANGED_MODE) {
    return false;
  }

  IMMDeviceEnumerator* enumerator = nullptr;
  HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                    CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                    reinterpret_cast<void**>(&enumerator));
  if (FAILED(result) || enumerator == nullptr) {
    if (should_uninitialize) {
      CoUninitialize();
    }
    return false;
  }

  bool active = false;
  IMMDevice* device = nullptr;
  result = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  if (SUCCEEDED(result) && device != nullptr) {
    IAudioMeterInformation* meter = nullptr;
    result = device->Activate(__uuidof(IAudioMeterInformation), CLSCTX_ALL,
                              nullptr, reinterpret_cast<void**>(&meter));
    if (SUCCEEDED(result) && meter != nullptr) {
      float peak = 0.0f;
      if (SUCCEEDED(meter->GetPeakValue(&peak))) {
        active = peak > 0.003f;
      }
      meter->Release();
    }
    device->Release();
  }
  enumerator->Release();

  if (should_uninitialize) {
    CoUninitialize();
  }
  return active;
}

}  // namespace

std::function<void()> RegisterExternalRouteChannel(
    flutter::BinaryMessenger* messenger) {
  const HRESULT ro_result = RoInitialize(RO_INIT_MULTITHREADED);
  const bool ro_initialized = SUCCEEDED(ro_result);

  auto channel = std::make_shared<flutter::MethodChannel<EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [channel](const flutter::MethodCall<EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const auto& method = call.method_name();
        if (method == "listBluetoothDevices") {
          const std::wstring script =
              LR"ps(
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
function Await-Operation($operation, [Type]$resultType) {
  $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
      $_.Name -eq 'AsTask' -and
      $_.IsGenericMethod -and
      $_.GetParameters().Count -eq 1 -and
      $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } |
    Select-Object -First 1
  $task = $asTask.MakeGenericMethod($resultType).Invoke($null, @($operation))
  return $task.GetAwaiter().GetResult()
}
$selector = [Windows.Media.Audio.AudioPlaybackConnection, Windows.Media, ContentType=WindowsRuntime]::GetDeviceSelector()
$operation = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]::FindAllAsync($selector)
$collectionType = [Windows.Devices.Enumeration.DeviceInformationCollection, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
$devices = Await-Operation $operation $collectionType
$devices | ForEach-Object {
  [pscustomobject]@{ id = $_.Id; name = $_.Name; isConnected = $false }
} | ConvertTo-Json -Compress
)ps";
          auto value = RunPowerShellJson(script);
          result->Success(value);
          return;
        }
        if (method == "startBluetoothSink") {
          const auto device_id = Utf16FromUtf8(StringArg(call.arguments(), "deviceId"));
          if (device_id.empty()) {
            auto value = Status("error", "Missing Bluetooth device ID.");
            result->Success(value);
            return;
          }
          auto value = StartPersistentBluetoothSink(device_id);
          result->Success(value);
          return;
        }
        if (method == "stopBluetoothSink") {
          StopBluetoothProcess();
          auto value = Status("stopped", "Bluetooth audio receiver released.");
          result->Success(value);
          return;
        }
        if (method == "scanAuracastBroadcasts") {
          int seconds = IntArg(call.arguments(), "seconds", 12);
          if (seconds < 3) {
            seconds = 3;
          } else if (seconds > 90) {
            seconds = 90;
          }
          std::wstring helper = CurrentExecutableDirectory();
          if (helper.empty()) {
            auto value = Status("error", "Could not locate application directory.");
            result->Success(value);
            return;
          }
          helper += L"\\audioshare_auracast_scanner.exe";
          if (GetFileAttributesW(helper.c_str()) == INVALID_FILE_ATTRIBUTES) {
            helper = CurrentExecutableDirectory() + L"\\AuracastScanner.exe";
          }
          if (GetFileAttributesW(helper.c_str()) == INVALID_FILE_ATTRIBUTES) {
            auto value = Status(
                "error",
                "Auracast scanner helper was not found. Build the Windows runner with dotnet installed.");
            result->Success(value);
            return;
          }
          std::wstring args = L"--seconds ";
          args += std::to_wstring(seconds);
          auto value = RunExecutableJson(helper, args,
                                         static_cast<DWORD>((seconds + 5) * 1000));
          result->Success(value);
          return;
        }
        if (method == "openWirelessDisplay") {
          const bool opened =
              LaunchUri(L"ms-settings:project") || LaunchUri(L"ms-settings:optionalfeatures");
          auto value = Status(opened ? "ready" : "error",
                              opened
                                  ? "Opened Windows projection settings. Install or open Wireless Display."
                                  : "Could not open Windows wireless display settings.");
          result->Success(value);
          return;
        }
        if (method == "isWindowsOutputActive") {
          EncodableValue value(IsDefaultOutputActive());
          result->Success(value);
          return;
        }
        result->NotImplemented();
      });

  return [channel, ro_initialized]() {
    StopBluetoothProcess();
    channel->SetMethodCallHandler(nullptr);
    if (ro_initialized) {
      RoUninitialize();
    }
  };
}
