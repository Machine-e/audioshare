#include "sink_open_retry.h"
#include "sink_state_machine.h"

#include <cstdlib>
#include <iostream>
#include <stdexcept>

using audioshare::OpenSinkWithRetry;
using audioshare::SinkOpenOutcome;
using audioshare::SinkState;
using audioshare::SinkStateMachine;

void Check(bool value, const char* reason) {
  if (!value) { std::cerr << reason << '\n'; std::exit(1); }
}

int main() {
  // Regression: the driver reports Opened and creates volume controls, but
  // its first render graph remains silent. Success must also cross the full
  // stop/start boundary once, with no premature connected/disconnected event.
  {
    SinkStateMachine state;
    const auto generation = state.Begin(0, true);
    int sessions = 0, closes = 0;
    bool alive = false;
    const auto result = audioshare::RecoverSinkSessionOnce([&] {
      Check(!alive, "warm-up object must be released before the real session");
      alive = true;
      ++sessions;
      state.Opened(generation);
      Check(!state.TakeChange(generation), "warm-up must not publish connected");
      return SinkOpenOutcome::opened;
    }, [&](auto reason) {
      Check(reason == SinkOpenOutcome::opened, "successful but silent warm-up is rebuilt");
      ++closes;
      alive = false;
      state.Closed(generation);
      Check(!state.terminal_applied(), "warm-up close is not a disconnect");
    }, [] { return true; }, true);
    Check(result == SinkOpenOutcome::opened && sessions == 2 && closes == 1,
          "success gets exactly one full rebuild, not an endless silence retry");
    state.FinishStartup(generation);
    state.Opened(generation);
    Check(state.TakeInitial(generation) == SinkState::opened,
          "only the final session is reported to the UI");
  }
  for (auto first : {SinkOpenOutcome::opened, SinkOpenOutcome::transient_failure,
                     SinkOpenOutcome::denied, SinkOpenOutcome::cancelled}) {
    for (auto second : {SinkOpenOutcome::opened, SinkOpenOutcome::transient_failure,
                        SinkOpenOutcome::denied, SinkOpenOutcome::cancelled}) {
      int sessions = 0, resets = 0;
      const auto result = audioshare::RecoverSinkSessionOnce(
          [&] { return ++sessions == 1 ? first : second; },
          [&](auto) { ++resets; }, [] { return true; }, true);
      const bool rebuild = first == SinkOpenOutcome::opened ||
                           first == SinkOpenOutcome::transient_failure;
      Check(sessions == (rebuild ? 2 : 1) && resets == (rebuild ? 1 : 0),
            "warm-up and failure recovery share a single rebuild budget");
      Check(result == (rebuild ? second : first),
            "final failure cannot be masked by successful warm-up");
    }
  }
  {
    int sessions = 0;
    bool current = true;
    const auto result = audioshare::RecoverSinkSessionOnce([&] {
      ++sessions;
      return SinkOpenOutcome::opened;
    }, [&](auto) { current = false; }, [&] { return current; }, true);
    Check(result == SinkOpenOutcome::cancelled && sessions == 1,
          "stop or device change during warm-up cannot reopen the old device");
  }
  {
    int sessions = 0, closes = 0;
    bool failed_session_alive = false;
    const auto result = audioshare::RecoverSinkSessionOnce([&] {
      Check(!failed_session_alive, "old connection released before recreation");
      ++sessions;
      failed_session_alive = true;
      return sessions == 1 ? SinkOpenOutcome::transient_failure : SinkOpenOutcome::opened;
    }, [&](auto) { ++closes; failed_session_alive = false; }, [] { return true; });
    Check(result == SinkOpenOutcome::opened && sessions == 2 && closes == 1,
          "failed first session recovers without a second user request");
  }
  for (auto outcome : {SinkOpenOutcome::opened, SinkOpenOutcome::denied,
                       SinkOpenOutcome::cancelled, SinkOpenOutcome::transient_failure}) {
    int attempts = 0, resets = 0;
    const auto result = audioshare::RecoverSinkSessionOnce([&] { ++attempts; return outcome; },
        [&](auto) { ++resets; }, [] { return true; });
    Check(result == outcome, "recovery preserves final outcome");
    Check(attempts == (outcome == SinkOpenOutcome::transient_failure ? 2 : 1),
          "only failed sessions are rebuilt, at most once");
    Check(resets == (outcome == SinkOpenOutcome::transient_failure ? 1 : 0),
          "successful or denied connections are never reset");
  }
  {
    bool current = true;
    int attempts = 0;
    const auto result = audioshare::RecoverSinkSessionOnce([&] {
      ++attempts; return SinkOpenOutcome::transient_failure;
    }, [&](auto) { current = false; }, [&] { return current; });
    Check(result == SinkOpenOutcome::cancelled && attempts == 1,
          "stop during disposal prevents a new connection");
  }
  for (int failures = 0; failures <= 3; ++failures) {
    int calls = 0;
    std::chrono::milliseconds::rep elapsed = 0;
    SinkStateMachine state;
    const auto generation = state.Begin(0, true);
    auto result = OpenSinkWithRetry([&] {
      ++calls;
      // A driver may emit these during every OpenAsync, including a failed one.
      state.Opened(generation); state.Closed(generation);
      Check(!state.terminal_applied(), "negotiation must not destroy the sink");
      return calls <= failures ? SinkOpenOutcome::transient_failure
                               : SinkOpenOutcome::opened;
    }, [] { return true; }, [&](auto duration) { elapsed += duration.count(); });
    Check(calls == (failures < 3 ? failures + 1 : 3), "bounded attempt count");
    Check(elapsed == (failures == 0 ? 0 : failures == 1 ? 500 : 1500), "backoff schedule");
    Check(result == (failures < 3 ? SinkOpenOutcome::opened : SinkOpenOutcome::transient_failure),
          "failed opens cannot masquerade as success");
    if (result == SinkOpenOutcome::opened) {
      state.FinishStartup(generation);
      state.Opened(generation);
      Check(state.TakeInitial(generation) == SinkState::opened,
            "first user request recovers on the same connection");
    }
  }
  int calls = 0, sleeps = 0;
  auto result = OpenSinkWithRetry([&] { ++calls; return SinkOpenOutcome::denied; },
      [] { return true; }, [&](auto) { ++sleeps; });
  Check(result == SinkOpenOutcome::denied && calls == 1 && sleeps == 0,
        "system denial is not retried");
  calls = 0;
  result = OpenSinkWithRetry([&] { ++calls; return SinkOpenOutcome::opened; },
      [] { return false; }, [](auto) {});
  Check(result == SinkOpenOutcome::cancelled && calls == 0, "cancel before open");
  bool current = true;
  result = OpenSinkWithRetry([&] { ++calls; current = false; return SinkOpenOutcome::opened; },
      [&] { return current; }, [](auto) {});
  Check(result == SinkOpenOutcome::cancelled && calls == 1, "ignore late success after stop");
  calls = 0; current = true;
  result = OpenSinkWithRetry([&] { ++calls; return SinkOpenOutcome::transient_failure; },
      [&] { return current; }, [&](auto) { current = false; });
  Check(result == SinkOpenOutcome::cancelled && calls == 1,
        "cancellation during backoff prevents another open");
  calls = 0;
  try {
    OpenSinkWithRetry([&]() -> SinkOpenOutcome { ++calls; throw std::runtime_error("driver failure"); },
        [] { return true; }, [](auto) {});
    Check(false, "unexpected native exceptions must reach resource cleanup");
  } catch (const std::runtime_error&) { Check(calls == 1, "do not retry arbitrary exceptions"); }
  std::cout << "sink_open_retry_test passed\n";
}
