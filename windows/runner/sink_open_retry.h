#pragma once

#include <chrono>

namespace audioshare {

enum class SinkOpenOutcome { opened, transient_failure, denied, cancelled };

// Repeating OpenAsync on the same driver session does not reproduce a manual
// stop/start. Some A2DP drivers also report success and expose volume controls
// for a silent first session. With prime_opened enabled, treat that first open
// as a warm-up and rebuild before publishing startup success. Failure recovery
// and warm-up share ONE rebuild budget; never loop on silence or reset on deny.
template <typename Attempt, typename Reset, typename Current>
SinkOpenOutcome RecoverSinkSessionOnce(Attempt attempt, Reset reset,
                                      Current current, bool prime_opened = false) {
  if (!current()) return SinkOpenOutcome::cancelled;
  auto outcome = attempt();
  if (!current()) return SinkOpenOutcome::cancelled;
  if (outcome != SinkOpenOutcome::transient_failure &&
      !(prime_opened && outcome == SinkOpenOutcome::opened)) return outcome;
  reset(outcome);
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
