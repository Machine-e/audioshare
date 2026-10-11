#include "bluetooth_status_server.h"

#include <winsock2.h>
#include <ws2bth.h>
#include <windows.h>
#include <BluetoothAPIs.h>

#include <chrono>
#include <mutex>
#include <sstream>
#include <thread>

namespace audioshare {
namespace {
constexpr GUID kStatusServiceGuid = {0x8fa6bca1, 0xbd4c, 0x4bde,
                                     {0xbd, 0x1c, 0xc7, 0xb4, 0x5e, 0x05, 0xa7, 0x11}};

std::string SocketError(const char* text) {
  return std::string(text) + " (Winsock error " + std::to_string(WSAGetLastError()) + ")";
}
}  // namespace

class BluetoothStatusServer::Impl {
 public:
  explicit Impl(SnapshotCallback snapshot) : snapshot_(std::move(snapshot)) {}
  ~Impl() { Stop(); }

  void Start() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (worker_.joinable()) return;
    stopping_ = false;
    worker_ = std::thread([this] { Run(); });
  }

  void Stop() {
    std::thread worker;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopping_ = true;
      if (listener_ != INVALID_SOCKET) shutdown(listener_, SD_BOTH);
      if (client_ != INVALID_SOCKET) shutdown(client_, SD_BOTH);
      worker = std::move(worker_);
    }
    if (worker.joinable()) worker.join();
  }

  BluetoothStatusServiceInfo GetInfo() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return info_;
  }

 private:
  static void CloseSocket(SOCKET& socket) {
    if (socket == INVALID_SOCKET) return;
    shutdown(socket, SD_BOTH);
    closesocket(socket);
    socket = INVALID_SOCKET;
  }

  bool IsStopping() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return stopping_;
  }

  void SetInfo(bool available, std::string message) {
    std::lock_guard<std::mutex> lock(mutex_);
    info_ = {available, std::move(message)};
  }

  bool IsPaired(BTH_ADDR address) const {
    BLUETOOTH_DEVICE_INFO device{};
    device.dwSize = sizeof(device);
    device.Address.ullLong = address;
    return BluetoothGetDeviceInfo(nullptr, &device) == ERROR_SUCCESS && device.fAuthenticated;
  }

  bool PublishSocket(SOCKET& slot, SOCKET socket) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_) {
      shutdown(socket, SD_BOTH);
      closesocket(socket);
      return false;
    }
    slot = socket;
    return true;
  }

  void Serve(SOCKET socket, BTH_ADDR peer) {
    u_long blocking = 0;
    const DWORD timeout_ms = 1000;
    if (ioctlsocket(socket, FIONBIO, &blocking) == SOCKET_ERROR ||
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO,
                   reinterpret_cast<const char*>(&timeout_ms),
                   sizeof(timeout_ms)) == SOCKET_ERROR) {
      SetInfo(false, SocketError("Bluetooth status client timeout could not be configured"));
      return;
    }
    uint64_t frames = 0;
    while (!IsStopping()) {
      // Recheck immediately before exposing status in case pairing was removed
      // after accept.
      if (!IsPaired(peer)) break;
      BluetoothStatusSnapshot status;
      try {
        status = snapshot_(static_cast<uint64_t>(peer));
      } catch (...) {
        SetInfo(false, "Bluetooth status snapshot failed.");
        return;
      }
      std::ostringstream json;
      json << "{\"v\":1,\"mode\":\"" << status.mode
           << "\",\"target\":\"" << status.target << "\"}\n";
      const std::string line = json.str();
      if (line.size() > 512 ||
          send(socket, line.data(), static_cast<int>(line.size()), 0) !=
              static_cast<int>(line.size())) break;
      SetInfo(true, "Phone status channel connected; frames sent: " +
                    std::to_string(++frames) + "; receiver: " + status.mode +
                    "; target: " + status.target);
      for (int elapsed = 0; elapsed < 10 && !IsStopping(); ++elapsed)
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
  }

  void Run() noexcept {
    try {
      RunCore();
    } catch (...) {
      SetInfo(false, "Bluetooth status service failed unexpectedly.");
      Finish(nullptr);
    }
  }

  void RunCore() {
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
      SetInfo(false, SocketError("Bluetooth status service could not initialize"));
      return;
    }
    SOCKET listener = socket(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM);
    if (listener == INVALID_SOCKET) {
      SetInfo(false, SocketError("Bluetooth status socket could not be created"));
      WSACleanup();
      return;
    }
    if (!PublishSocket(listener_, listener)) {
      WSACleanup();
      return;
    }
    const ULONG enabled = TRUE;
    if (setsockopt(listener, SOL_RFCOMM, SO_BTH_AUTHENTICATE,
                   reinterpret_cast<const char*>(&enabled), sizeof(enabled)) == SOCKET_ERROR ||
        setsockopt(listener, SOL_RFCOMM, SO_BTH_ENCRYPT,
                   reinterpret_cast<const char*>(&enabled), sizeof(enabled)) == SOCKET_ERROR) {
      SetInfo(false, SocketError("Bluetooth authentication/encryption is unavailable"));
      Finish(nullptr);
      return;
    }
    SOCKADDR_BTH local{};
    local.addressFamily = AF_BTH;
    local.port = BT_PORT_ANY;
    if (bind(listener, reinterpret_cast<SOCKADDR*>(&local), sizeof(local)) == SOCKET_ERROR ||
        listen(listener, 1) == SOCKET_ERROR) {
      SetInfo(false, SocketError("Bluetooth status service could not bind (another instance may be running)"));
      Finish(nullptr);
      return;
    }
    int local_size = sizeof(local);
    u_long nonblocking = 1;
    if (ioctlsocket(listener, FIONBIO, &nonblocking) == SOCKET_ERROR) {
      SetInfo(false, SocketError("Bluetooth status listener could not become nonblocking"));
      Finish(nullptr);
      return;
    }
    if (getsockname(listener, reinterpret_cast<SOCKADDR*>(&local),
                    &local_size) == SOCKET_ERROR) {
      SetInfo(false, SocketError("Bluetooth status service address could not be read"));
      Finish(nullptr);
      return;
    }
    CSADDR_INFO address{};
    address.LocalAddr.lpSockaddr = reinterpret_cast<SOCKADDR*>(&local);
    address.LocalAddr.iSockaddrLength = sizeof(local);
    // Bluetooth automatic SDP generation uses both endpoints, as in the
    // Microsoft WinsockBluetoothConnection sample. Publish the assigned port.
    address.RemoteAddr.lpSockaddr = reinterpret_cast<SOCKADDR*>(&local);
    address.RemoteAddr.iSockaddrLength = sizeof(local);
    address.iSocketType = SOCK_STREAM;
    address.iProtocol = BTHPROTO_RFCOMM;
    WSAQUERYSET service{};
    service.dwSize = sizeof(service);
    service.lpszServiceInstanceName = const_cast<wchar_t*>(L"AudioShare status");
    GUID service_guid = kStatusServiceGuid;
    service.lpServiceClassId = &service_guid;
    service.dwNameSpace = NS_BTH;
    service.dwNumberOfCsAddrs = 1;
    service.lpcsaBuffer = &address;
    if (WSASetService(&service, RNRSERVICE_REGISTER, 0) == SOCKET_ERROR) {
      SetInfo(false, SocketError("Bluetooth status SDP registration failed"));
      Finish(nullptr);
      return;
    }
    try {
      SetInfo(true, "Service registered; waiting for phone status connection (not audio). RFCOMM channel: " + std::to_string(local.port));
      while (!IsStopping()) {
        SOCKADDR_BTH remote{};
        int remote_size = sizeof(remote);
        SOCKET client = accept(listener, reinterpret_cast<SOCKADDR*>(&remote), &remote_size);
        if (client == INVALID_SOCKET) {
          if (WSAGetLastError() == WSAEWOULDBLOCK) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            continue;
          }
          if (!IsStopping())
            SetInfo(false, SocketError("Bluetooth status service stopped accepting clients"));
          break;
        }
        if (!PublishSocket(client_, client)) break;
        if (IsPaired(remote.btAddr)) Serve(client, remote.btAddr);
        {
          std::lock_guard<std::mutex> lock(mutex_);
          CloseSocket(client_);
        }
        if (!IsStopping())
          SetInfo(true, "Phone status channel closed; waiting for reconnect (audio is independent).");
      }
    } catch (...) {
      SetInfo(false, "Bluetooth status service failed unexpectedly.");
    }
    Finish(&service);
  }

  void Finish(WSAQUERYSET* service) {
    if (service) WSASetService(service, RNRSERVICE_DELETE, 0);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      CloseSocket(client_);
      CloseSocket(listener_);
      if (info_.available) {
        info_.available = false;
        info_.message = stopping_ ? "Bluetooth status service is stopped."
                                  : "Bluetooth status service is unavailable.";
      }
    }
    WSACleanup();
  }

  SnapshotCallback snapshot_;
  mutable std::mutex mutex_;
  bool stopping_ = false;
  SOCKET listener_ = INVALID_SOCKET;
  SOCKET client_ = INVALID_SOCKET;
  std::thread worker_;
  BluetoothStatusServiceInfo info_{false, "Bluetooth status service is starting."};
};

BluetoothStatusServer::BluetoothStatusServer(SnapshotCallback snapshot)
    : impl_(std::make_unique<Impl>(std::move(snapshot))) {}
BluetoothStatusServer::~BluetoothStatusServer() = default;
void BluetoothStatusServer::Start() { impl_->Start(); }
void BluetoothStatusServer::Stop() { impl_->Stop(); }
BluetoothStatusServiceInfo BluetoothStatusServer::GetInfo() const { return impl_->GetInfo(); }

}  // namespace audioshare
