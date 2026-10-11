#pragma once

#include <windows.h>
#include <shlobj.h>

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>

namespace audioshare {

// Local, bounded diagnostics for comparing the first connection with a retry.
// Never record device IDs, addresses, audio contents, or remote messages.
inline void TraceConnection(uint64_t generation, const std::string& event) noexcept {
  try {
    static std::mutex mutex;
    std::lock_guard<std::mutex> lock(mutex);
    wchar_t local[MAX_PATH]{};
    if (FAILED(SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr,
                              SHGFP_TYPE_CURRENT, local))) return;
    const auto directory = std::filesystem::path(local) / L"AudioShare";
    std::filesystem::create_directories(directory);
    const auto path = directory / L"connection.log";
    const bool full = std::filesystem::exists(path) &&
                      std::filesystem::file_size(path) > 128 * 1024;
    std::ofstream stream(path, full ? std::ios::trunc : std::ios::app);
    stream << "pid=" << GetCurrentProcessId() << " tick=" << GetTickCount64()
           << " session=" << generation << " " << event << '\n';
  } catch (...) {
    // Diagnostics must never affect the audio connection.
  }
}

}  // namespace audioshare
