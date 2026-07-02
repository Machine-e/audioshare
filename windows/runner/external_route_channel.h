#ifndef RUNNER_EXTERNAL_ROUTE_CHANNEL_H_
#define RUNNER_EXTERNAL_ROUTE_CHANNEL_H_

#include <flutter/binary_messenger.h>

#include <functional>

std::function<void()> RegisterExternalRouteChannel(
    flutter::BinaryMessenger* messenger);

#endif  // RUNNER_EXTERNAL_ROUTE_CHANNEL_H_
