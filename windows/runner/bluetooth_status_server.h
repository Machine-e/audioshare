#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace audioshare {

struct BluetoothStatusSnapshot {
  std::string mode;
  std::string target;
};

struct BluetoothStatusServiceInfo {
  bool available = false;
  std::string message;
};

// Read-only authenticated/encrypted RFCOMM protocol. After accepting one paired
// peer, the server sends one UTF-8 JSON line (at most 512 bytes) each second:
// {"v":1,"mode":"...","target":"..."}\n. Clients send no commands.
class BluetoothStatusServer {
 public:
  using SnapshotCallback = std::function<BluetoothStatusSnapshot(uint64_t)>;

  explicit BluetoothStatusServer(SnapshotCallback snapshot);
  ~BluetoothStatusServer();
  BluetoothStatusServer(const BluetoothStatusServer&) = delete;
  BluetoothStatusServer& operator=(const BluetoothStatusServer&) = delete;

  void Start();
  void Stop();
  BluetoothStatusServiceInfo GetInfo() const;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace audioshare
