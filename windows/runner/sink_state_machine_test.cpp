#include "sink_state_machine.h"
#include <cstdlib>
#include <iostream>
using audioshare::SinkState;
using audioshare::SinkStateMachine;
void Check(bool value, const char* text) { if (!value) { std::cerr << text << '\n'; std::exit(1); } }
int main() {
  SinkStateMachine m;
  auto g = m.Begin(); Check(m.Waiting(g), "first waiting"); Check(m.Opened(g), "first opened");
  Check(!m.Opened(g), "duplicate opened is not a change");
  Check(!m.Waiting(g), "opened cannot regress to waiting");
  Check(m.Closed(g), "opened then closed");
  Check(m.TakeChange(g) == SinkState::waitingForRoute, "waiting order");
  Check(m.TakeChange(g) == SinkState::opened, "opened order");
  Check(m.TakeChange(g) == SinkState::disconnected, "disconnected order");
  Check(!m.Closed(g), "terminal once");
  g = m.Begin(); m.Waiting(g); m.Opened(g); Check(m.TakeInitial(g) == SinkState::opened, "initial opened");
  Check(!m.TakeChange(g), "initial consumes prior events");
  m.Closed(g); Check(m.TakeChange(g) == SinkState::disconnected, "gap caches disconnect");
  Check(!m.TakeChange(g), "terminal delivered once");
  g = m.Begin(); m.Opened(g); m.Closed(g);
  Check(m.TakeInitial(g) == SinkState::disconnected, "terminal before initial is preserved");
  Check(!m.TakeChange(g), "initial terminal delivered once");
  g = m.Begin(); m.Opened(g); m.TakeInitial(g); m.Closed(g);
  Check(m.TakeChange(g) == SinkState::disconnected, "terminal during reattach gap");
  auto old = g; g = m.Begin(); m.Stop(); m.Opened(old); Check(m.state() == SinkState::stopped, "old generation ignored");
  m.Error(g); Check(m.state() == SinkState::stopped, "cancel generation ignored");
  std::cout << "sink_state_machine_test passed\n";
}
