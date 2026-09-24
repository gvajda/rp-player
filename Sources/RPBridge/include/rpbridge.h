#pragma once

#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>
#include "ladspa.h"

void rpbridge_set_unit(AudioUnit _Nullable unit);
uint64_t rpbridge_frames_processed(void);
