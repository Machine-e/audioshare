#pragma once
#include <cstdint>
#include <deque>
#include <optional>

namespace audioshare {
enum class SinkState { stopped, waitingForRoute, opened, disconnected, error };

// Pure state/event delivery core. The channel owns synchronization and resources.
class SinkStateMachine {
 public:
  uint64_t Begin(uint64_t generation = 0, bool startup_pending = false);
  bool FinishStartup(uint64_t generation);
  bool startup_pending() const { return startup_pending_; }
  bool Waiting(uint64_t generation);
  bool Opened(uint64_t generation);
  bool Closed(uint64_t generation);
  bool Error(uint64_t generation);
  void Stop();
  SinkState TakeInitial(uint64_t generation);
  std::optional<SinkState> TakeChange(uint64_t generation);
  SinkState state() const { return state_; }
  uint64_t generation() const { return generation_; }
  bool terminal_applied() const { return terminal_applied_; }

 private:
  bool Transition(SinkState next);
  uint64_t generation_ = 0;
  SinkState state_ = SinkState::stopped;
  bool opened_once_ = false;
  bool terminal_applied_ = true;
  bool startup_pending_ = false;
  std::deque<SinkState> changes_;
};
}  // namespace audioshare
