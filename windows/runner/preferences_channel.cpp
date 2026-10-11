#include "preferences_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <string>
#include <variant>
#include <vector>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;
constexpr char kChannelName[] = "com.machinee.audioshare/preferences";
constexpr wchar_t kRegistryPath[] = L"Software\\AudioShare";
constexpr wchar_t kRegistryValue[] = L"preferred device";

std::wstring ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                                       static_cast<int>(value.size()), nullptr, 0);
  if (!size) return {};
  std::wstring wide(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), wide.data(), size);
  return wide;
}

std::string ToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                                       static_cast<int>(value.size()), nullptr, 0,
                                       nullptr, nullptr);
  if (!size) return {};
  std::string utf8(size, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), utf8.data(), size, nullptr, nullptr);
  return utf8;
}
}  // namespace

std::function<void()> RegisterPreferencesChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_shared<flutter::MethodChannel<EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() == "readThemeMode") {
          wchar_t value[16]{};
          DWORD bytes = sizeof(value);
          const auto status = RegGetValueW(HKEY_CURRENT_USER, kRegistryPath,
              L"theme mode", RRF_RT_REG_SZ, nullptr, value, &bytes);
          if (status == ERROR_SUCCESS) result->Success(EncodableValue(ToUtf8(value)));
          else if (status == ERROR_FILE_NOT_FOUND) result->Success();
          else result->Error("preference_read_failed", "Could not read appearance.");
          return;
        }
        if (call.method_name() == "writeThemeMode") {
          std::string mode;
          if (call.arguments() && std::holds_alternative<EncodableMap>(*call.arguments())) {
            const auto& args = std::get<EncodableMap>(*call.arguments());
            const auto it = args.find(EncodableValue("mode"));
            if (it != args.end() && std::holds_alternative<std::string>(it->second))
              mode = std::get<std::string>(it->second);
          }
          if (mode != "light" && mode != "dark" && mode != "system") {
            result->Error("invalid_theme", "Unknown appearance."); return;
          }
          const auto wide = ToWide(mode);
          const auto status = RegSetKeyValueW(HKEY_CURRENT_USER, kRegistryPath,
              L"theme mode", REG_SZ, wide.c_str(),
              static_cast<DWORD>((wide.size() + 1) * sizeof(wchar_t)));
          if (status == ERROR_SUCCESS) result->Success();
          else result->Error("preference_write_failed", "Could not save appearance.");
          return;
        }
        if (call.method_name() == "readPreferredDevice") {
          DWORD type = 0;
          DWORD bytes = 0;
          LSTATUS status = RegGetValueW(HKEY_CURRENT_USER, kRegistryPath, kRegistryValue,
                                        RRF_RT_REG_SZ, &type, nullptr, &bytes);
          if (status == ERROR_FILE_NOT_FOUND) {
            result->Success();
            return;
          }
          if (status != ERROR_SUCCESS) {
            result->Error("registry_read_failed", "Could not read preferred device.",
                          EncodableValue(static_cast<int32_t>(status)));
            return;
          }
          std::vector<wchar_t> buffer(bytes / sizeof(wchar_t));
          status = RegGetValueW(HKEY_CURRENT_USER, kRegistryPath, kRegistryValue,
                                RRF_RT_REG_SZ, &type, buffer.data(), &bytes);
          if (status != ERROR_SUCCESS) {
            result->Error("registry_read_failed", "Could not read preferred device.",
                          EncodableValue(static_cast<int32_t>(status)));
            return;
          }
          result->Success(EncodableValue(ToUtf8(buffer.data())));
          return;
        }
        if (call.method_name() == "writePreferredDevice") {
          std::string device_id;
          if (call.arguments() && std::holds_alternative<EncodableMap>(*call.arguments())) {
            const auto& args = std::get<EncodableMap>(*call.arguments());
            const auto it = args.find(EncodableValue("deviceId"));
            if (it != args.end() && std::holds_alternative<std::string>(it->second))
              device_id = std::get<std::string>(it->second);
          }
          const std::wstring wide = ToWide(device_id);
          if (device_id.empty() || wide.empty()) {
            result->Error("invalid_device_id", "deviceId must be a non-empty UTF-8 string.");
            return;
          }
          HKEY key = nullptr;
          LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, kRegistryPath, 0, nullptr, 0,
                                           KEY_SET_VALUE, nullptr, &key, nullptr);
          if (status == ERROR_SUCCESS) {
            status = RegSetValueExW(key, kRegistryValue, 0, REG_SZ,
                                    reinterpret_cast<const BYTE*>(wide.c_str()),
                                    static_cast<DWORD>((wide.size() + 1) * sizeof(wchar_t)));
            RegCloseKey(key);
          }
          if (status != ERROR_SUCCESS) {
            result->Error("registry_write_failed", "Could not write preferred device.",
                          EncodableValue(static_cast<int32_t>(status)));
            return;
          }
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  return [channel]() { channel->SetMethodCallHandler(nullptr); };
}
