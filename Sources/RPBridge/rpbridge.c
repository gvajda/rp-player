#include "rpbridge.h"

#include <os/log.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

enum { PORT_IN_L, PORT_IN_R, PORT_OUT_L, PORT_OUT_R, PORT_COUNT };
enum { MAX_FRAMES = 4096 };

typedef struct {
    unsigned long rate;
    LADSPA_Data *ports[PORT_COUNT];
} Instance;

typedef struct {
    UInt32 mNumberBuffers;
    AudioBuffer mBuffers[2];
} StereoBufferList;

// The filter runs on mpv's filter thread, not the CoreAudio IO thread, so a mutex around run() is acceptable.
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static AudioUnit current_unit;
static double configured_rate;
static double failed_rate;
static bool needs_reset;
static bool render_error_logged;
static Float64 sample_time;
static uint64_t frames_processed;
static const LADSPA_Data *chunk_in[2];
static UInt32 chunk_frames;

static os_log_t log_handle;
static pthread_once_t log_once = PTHREAD_ONCE_INIT;

static void make_log(void) { log_handle = os_log_create("com.gvajda.RPPlayer", "bridge"); }

static os_log_t bridge_log(void) {
    pthread_once(&log_once, make_log);
    return log_handle;
}

static OSStatus input_proc(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                           UInt32 bus, UInt32 frames, AudioBufferList *io) {
    (void)ref; (void)flags; (void)ts; (void)bus;
    if (frames > chunk_frames) return kAudioUnitErr_TooManyFramesToProcess;
    for (UInt32 ch = 0; ch < io->mNumberBuffers && ch < 2; ch++) {
        UInt32 bytes = frames * (UInt32)sizeof(float);
        if (io->mBuffers[ch].mData == NULL) {
            io->mBuffers[ch].mData = (void *)chunk_in[ch];
        } else {
            memcpy(io->mBuffers[ch].mData, chunk_in[ch], bytes);
        }
        io->mBuffers[ch].mDataByteSize = bytes;
    }
    return noErr;
}

static bool configure(double rate) {
    AudioUnitUninitialize(current_unit);
    AudioStreamBasicDescription format = {
        .mSampleRate = rate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
        .mBytesPerPacket = sizeof(float),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = sizeof(float),
        .mChannelsPerFrame = 2,
        .mBitsPerChannel = 32,
    };
    UInt32 max_frames = MAX_FRAMES;
    AURenderCallbackStruct callback = { input_proc, NULL };
    OSStatus st = AudioUnitSetProperty(current_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof format);
    if (st == noErr) st = AudioUnitSetProperty(current_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, sizeof format);
    if (st == noErr) st = AudioUnitSetProperty(current_unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &max_frames, sizeof max_frames);
    if (st == noErr) st = AudioUnitSetProperty(current_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof callback);
    if (st == noErr) st = AudioUnitInitialize(current_unit);
    if (st != noErr) {
        os_log_error(bridge_log(), "configuring the audio unit at %.0f Hz failed: %d", rate, (int)st);
        return false;
    }
    AudioUnitReset(current_unit, kAudioUnitScope_Global, 0);
    return true;
}

static bool render_chunk(Instance *inst, unsigned long offset, UInt32 n) {
    chunk_in[0] = inst->ports[PORT_IN_L] + offset;
    chunk_in[1] = inst->ports[PORT_IN_R] + offset;
    chunk_frames = n;
    UInt32 bytes = n * (UInt32)sizeof(float);
    StereoBufferList out = { 2, {
        { 1, bytes, inst->ports[PORT_OUT_L] + offset },
        { 1, bytes, inst->ports[PORT_OUT_R] + offset },
    } };
    AudioTimeStamp ts = { .mSampleTime = sample_time, .mFlags = kAudioTimeStampSampleTimeValid };
    AudioUnitRenderActionFlags flags = 0;
    OSStatus st = AudioUnitRender(current_unit, &flags, &ts, 0, n, (AudioBufferList *)&out);
    sample_time += n;
    if (st != noErr) {
        if (!render_error_logged) {
            os_log_error(bridge_log(), "audio unit render failed: %d; passing audio through", (int)st);
            render_error_logged = true;
        }
        return false;
    }
    for (int ch = 0; ch < 2; ch++) {
        float *dst = inst->ports[PORT_OUT_L + ch] + offset;
        if (out.mBuffers[ch].mData != dst) memcpy(dst, out.mBuffers[ch].mData, bytes);
    }
    return true;
}

static void copy_through(Instance *inst, unsigned long offset, unsigned long n) {
    for (int ch = 0; ch < 2; ch++) {
        memcpy(inst->ports[PORT_OUT_L + ch] + offset, inst->ports[PORT_IN_L + ch] + offset, n * sizeof(LADSPA_Data));
    }
}

static LADSPA_Handle instantiate(const LADSPA_Descriptor *descriptor, unsigned long rate) {
    (void)descriptor;
    Instance *inst = calloc(1, sizeof *inst);
    if (inst) inst->rate = rate;
    return inst;
}

static void connect_port(LADSPA_Handle handle, unsigned long port, LADSPA_Data *data) {
    if (port < PORT_COUNT) ((Instance *)handle)->ports[port] = data;
}

static void activate(LADSPA_Handle handle) {
    (void)handle;
    pthread_mutex_lock(&lock);
    needs_reset = true;
    pthread_mutex_unlock(&lock);
}

static void run(LADSPA_Handle handle, unsigned long sample_count) {
    Instance *inst = handle;
    double rate = (double)inst->rate;
    pthread_mutex_lock(&lock);
    if (current_unit && configured_rate != rate && failed_rate != rate) {
        if (configure(rate)) {
            configured_rate = rate;
        } else {
            configured_rate = 0;
            failed_rate = rate;
        }
        needs_reset = false;
    }
    bool active = current_unit && configured_rate == rate;
    if (active && needs_reset) {
        AudioUnitReset(current_unit, kAudioUnitScope_Global, 0);
        needs_reset = false;
    }
    for (unsigned long offset = 0; offset < sample_count; offset += MAX_FRAMES) {
        unsigned long left = sample_count - offset;
        UInt32 n = (UInt32)(left < MAX_FRAMES ? left : MAX_FRAMES);
        if (!active || !render_chunk(inst, offset, n)) copy_through(inst, offset, n);
    }
    frames_processed += sample_count;
    pthread_mutex_unlock(&lock);
}

static void cleanup(LADSPA_Handle handle) { free(handle); }

static const LADSPA_PortDescriptor port_descriptors[PORT_COUNT] = {
    LADSPA_PORT_INPUT | LADSPA_PORT_AUDIO,
    LADSPA_PORT_INPUT | LADSPA_PORT_AUDIO,
    LADSPA_PORT_OUTPUT | LADSPA_PORT_AUDIO,
    LADSPA_PORT_OUTPUT | LADSPA_PORT_AUDIO,
};
static const char *const port_names[PORT_COUNT] = { "In L", "In R", "Out L", "Out R" };
static const LADSPA_PortRangeHint port_hints[PORT_COUNT] = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } };

// INPLACE_BROKEN: without it af_ladspa passes the input frame as the output (out = in), aliasing the port buffers.
static const LADSPA_Descriptor descriptor = {
    .UniqueID = 4094,
    .Label = "rpbridge",
    .Properties = LADSPA_PROPERTY_INPLACE_BROKEN,
    .Name = "RP Player Audio Unit bridge",
    .Maker = "RP Player",
    .Copyright = "GPL-2.0-or-later",
    .PortCount = PORT_COUNT,
    .PortDescriptors = port_descriptors,
    .PortNames = port_names,
    .PortRangeHints = port_hints,
    .instantiate = instantiate,
    .connect_port = connect_port,
    .activate = activate,
    .run = run,
    .cleanup = cleanup,
};

const LADSPA_Descriptor *ladspa_descriptor(unsigned long index) {
    return index == 0 ? &descriptor : NULL;
}

void rpbridge_set_unit(AudioUnit unit) {
    pthread_mutex_lock(&lock);
    current_unit = unit;
    configured_rate = 0;
    failed_rate = 0;
    needs_reset = false;
    render_error_logged = false;
    pthread_mutex_unlock(&lock);
}

uint64_t rpbridge_frames_processed(void) {
    pthread_mutex_lock(&lock);
    uint64_t value = frames_processed;
    pthread_mutex_unlock(&lock);
    return value;
}
