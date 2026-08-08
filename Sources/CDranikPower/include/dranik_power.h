// Power-management message types.
//
// These are macros in <IOKit/IOMessage.h>, built from err_system/err_sub
// arithmetic that Swift's importer cannot evaluate. Rather than hardcode the
// resulting numbers and hope they stay put, let the C preprocessor derive them
// from Apple's own headers and expose the results.

#ifndef DRANIK_POWER_H
#define DRANIK_POWER_H

#include <stdint.h>
#include <IOKit/IOMessage.h>

/// Idle sleep is about to begin; it can still be refused.
static const uint32_t kDRMessageCanSystemSleep = (uint32_t)kIOMessageCanSystemSleep;
/// Sleep is happening. Refusing succeeds but changes nothing.
static const uint32_t kDRMessageSystemWillSleep = (uint32_t)kIOMessageSystemWillSleep;
/// The wake sequence has begun.
static const uint32_t kDRMessageSystemWillPowerOn = (uint32_t)kIOMessageSystemWillPowerOn;
/// The machine is awake.
static const uint32_t kDRMessageSystemHasPoweredOn = (uint32_t)kIOMessageSystemHasPoweredOn;

#endif /* DRANIK_POWER_H */
