#include "ActivityProbe.h"
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct LSActivityPeak { _Atomic uint32_t bits; };
LSActivityPeak *ls_activity_create(void) {
    LSActivityPeak *peak = calloc(1, sizeof(*peak));
    if (peak) atomic_init(&peak->bits, 0);
    return peak;
}
void ls_activity_destroy(LSActivityPeak *peak) { free(peak); }
float ls_activity_take(LSActivityPeak *peak) {
    uint32_t bits = atomic_exchange_explicit(&peak->bits, 0, memory_order_relaxed);
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}
OSStatus ls_activity_callback(AudioDeviceID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *input_time,
    AudioBufferList *output, const AudioTimeStamp *output_time, void *context) {
    LSActivityPeak *peak = context;
    float value = 0;
    for (UInt32 b = 0; b < input->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        const float *samples = buffer->mData;
        if (!samples) continue;
        for (UInt32 i = 0; i < buffer->mDataByteSize / sizeof(float); i++) {
            float sample = fabsf(samples[i]);
            if (isfinite(sample) && sample > value) value = sample;
        }
    }
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    uint32_t old = atomic_load_explicit(&peak->bits, memory_order_relaxed);
    while (old < bits && !atomic_compare_exchange_weak_explicit(
        &peak->bits, &old, bits, memory_order_relaxed, memory_order_relaxed)) {}
    for (UInt32 b = 0; b < output->mNumberBuffers; b++)
        if (output->mBuffers[b].mData)
            memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    return noErr;
}

// Offline callback regression: both buffer layouts, finite filtering and atomic take/reset.
int ls_activity_check(void) {
    LSActivityPeak *peak = ls_activity_create();
    AudioBufferList *input = calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    if (!peak || !input) { free(input); free(peak); return 0; }
    AudioBufferList output = { .mNumberBuffers = 0 };
    AudioTimeStamp time = {0};
    float interleaved[] = {0, -0.25f, NAN, INFINITY, 0.5f, -INFINITY};
    input->mNumberBuffers = 1;
    input->mBuffers[0] = (AudioBuffer){2, sizeof(interleaved), interleaved};
    ls_activity_callback(0, &time, input, &time, &output, &time, peak);
    int ok = ls_activity_take(peak) == 0.5f && ls_activity_take(peak) == 0;
    float left[] = {0.1f, -0.2f}, right[] = {-0.75f, 0};
    input->mNumberBuffers = 2;
    input->mBuffers[0] = (AudioBuffer){1, sizeof(left), left};
    input->mBuffers[1] = (AudioBuffer){1, sizeof(right), right};
    ls_activity_callback(0, &time, input, &time, &output, &time, peak);
    ok = ok && ls_activity_take(peak) == 0.75f && ls_activity_take(peak) == 0;
    memset(left, 0, sizeof(left)); memset(right, 0, sizeof(right));
    ls_activity_callback(0, &time, input, &time, &output, &time, peak);
    ok = ok && ls_activity_take(peak) == 0;
    free(input);
    ls_activity_destroy(peak);
    return ok;
}
