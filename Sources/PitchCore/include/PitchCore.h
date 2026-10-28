#ifndef LIVE_STEMS_PITCH_CORE_H
#define LIVE_STEMS_PITCH_CORE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct LSPitch LSPitch;
LSPitch *ls_pitch_create(double sampleRate);
void ls_pitch_destroy(LSPitch *pitch);
void ls_pitch_set(LSPitch *pitch, int semitones);
void ls_pitch_reset(LSPitch *pitch);
void ls_pitch_process(LSPitch *pitch, float *left, float *right, uint32_t frames);
int ls_pitch_failed(LSPitch *pitch);
uint32_t ls_pitch_latency(LSPitch *pitch);
#ifdef __cplusplus
}
#endif
#endif
