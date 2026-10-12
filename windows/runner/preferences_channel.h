#ifndef RUNNER_PREFERENCES_CHANNEL_H_
#define RUNNER_PREFERENCES_CHANNEL_H_

#include <flutter/binary_messenger.h>

#include <functional>

std::function<void()> RegisterPreferencesChannel(flutter::BinaryMessenger* messenger,
                                               std::function<void()> appearance_changed);

#endif  // RUNNER_PREFERENCES_CHANNEL_H_
