#include "sink_state_machine.h"

namespace audioshare {
uint64_t SinkStateMachine::Begin(uint64_t generation, bool startup_pending) {
  generation_ = generation == 0 ? generation_ + 1 : generation;
  changes_.clear(); state_ = SinkState::stopped;
  startup_pending_ = startup_pending;
  opened_once_ = false; terminal_applied_ = false; return generation_;
}
bool SinkStateMachine::FinishStartup(uint64_t generation) {
  if (generation != generation_ || terminal_applied_) return false;
  startup_pending_ = false;
  return true;
}
bool SinkStateMachine::Transition(SinkState next) {
  if (state_ == next || terminal_applied_) return false;
  state_ = next; changes_.push_back(next);
  if (next == SinkState::disconnected || next == SinkState::error || next == SinkState::stopped) {
    terminal_applied_ = true;
    startup_pending_ = false;
  }
  return true;
}
bool SinkStateMachine::Waiting(uint64_t g) {
  return g == generation_ && !opened_once_ && Transition(SinkState::waitingForRoute);
}
bool SinkStateMachine::Opened(uint64_t g) {
  if (g != generation_ || startup_pending_) return false;
  opened_once_ = true;
  return Transition(SinkState::opened);
}
bool SinkStateMachine::Closed(uint64_t g) {
  if (g != generation_ || startup_pending_ || !opened_once_ || terminal_applied_) return false;
  Transition(SinkState::disconnected); return true;
}
bool SinkStateMachine::Error(uint64_t g) {
  if (g != generation_ || terminal_applied_) return false;
  Transition(SinkState::error); return true;
}
void SinkStateMachine::Stop() { ++generation_; changes_.clear(); state_ = SinkState::stopped; opened_once_ = false; terminal_applied_ = true; startup_pending_ = false; }
SinkState SinkStateMachine::TakeInitial(uint64_t g) { if (g != generation_) return SinkState::stopped; changes_.clear(); return state_; }
std::optional<SinkState> SinkStateMachine::TakeChange(uint64_t g) {
  if (g != generation_ || changes_.empty()) return std::nullopt;
  auto value = changes_.front(); changes_.pop_front(); return value;
}
}  // namespace audioshare
