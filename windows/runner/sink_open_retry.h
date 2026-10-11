#pragma once

#include <chrono>

namespace audioshare {

enum class SinkOpenOutcome { opened, transient_failure, denied, cancelled };

// Repeating OpenAsync on a failed driver session does not reproduce a manual
// disconnect/reconnect. After bounded open retries fail, rebuild once, provided
// the user's request is still current. Never reset an opened or denied route.
template <typename Attempt, typename Reset, typename Current>
SinkOpenOutcome RecoverSinkSessionOnce(Attempt attempt, Reset reset,
                                      Current current) {
  if (!current()) return SinkOpenOutcome::cancelled;
  auto outcome = attempt();
  if (!current()) return SinkOpenOutcome::cancelled;
  if (outcome != SinkOpenOutcome::transient_failure) return outcome;
  reset();
  if (!current()) return SinkOpenOutcome::cancelled;
  outcome = attempt();
  return current() ? outcome : SinkOpenOutcome::cancelled;
}

// Reuse the same started connection. Only opening is retried; callers retain
// ownership and decide when to release it. All callbacks run on the worker.
template <typename Open, typename Current, typename Sleep>
SinkOpenOutcome OpenSinkWithRetry(Open open, Current current, Sleep sleep) {
  for (int attempt = 0; attempt < 3; ++attempt) {
    if (!current()) return SinkOpenOutcome::cancelled;
    const auto outcome = open();
    if (!current()) return SinkOpenOutcome::cancelled;
    if (outcome != SinkOpenOutcome::transient_failure || attempt == 2)
      return outcome;
    // Short waits keep stop/device-change/shutdown responsive during backoff.
    for (int tick = 0; tick < (attempt + 1) * 10; ++tick) {
      if (!current()) return SinkOpenOutcome::cancelled;
      sleep(std::chrono::milliseconds(50));
    }
  }
  return SinkOpenOutcome::transient_failure;
}

}  // namespace audioshare
