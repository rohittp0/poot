#pragma once

#include <Arduino.h>
#include <stdarg.h>

#include "config.h"

namespace poot_diag {

inline bool enabled() { return poot::kEnableSerialDiagnostics; }

inline void logf(const char* scope, const char* format, ...) {
  if (!enabled()) {
    return;
  }

  char message[256];
  va_list args;
  va_start(args, format);
  vsnprintf(message, sizeof(message), format, args);
  va_end(args);

  Serial.printf("[%10lu] [%s] %s\n", millis(), scope, message);
}

}  // namespace poot_diag

