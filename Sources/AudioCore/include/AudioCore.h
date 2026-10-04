#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
typedef struct LSCore LSCore;
typedef struct {
    uint64_t source_frame, capture_nanos, render_nanos;
    float stem_weight;
} LSRenderSnapshot;
int ls_render_snapshot(LSCore * _Null_unspecified core, LSRenderSnapshot * _Null_unspecified snapshot);
LSCore * _Null_unspecified ls_create(double capture_rate, double render_rate);
void ls_destroy(LSCore * _Null_unspecified core);
uint32_t ls_capture_read(LSCore * _Null_unspecified core, float * _Null_unspecified samples, uint32_t frames);
// Capture consumer drops unread audio at a manual source change.
void ls_discard_capture(LSCore * _Null_unspecified core);
uint32_t ls_capture_read_timed(LSCore * _Null_unspecified core, float * _Null_unspecified samples, uint32_t frames, double * _Null_unspecified end_host_seconds);
uint32_t ls_output_write(LSCore * _Null_unspecified core, const float * _Null_unspecified samples, uint32_t frames);
uint32_t ls_output_write_timed(LSCore * _Null_unspecified core, const float * _Null_unspecified samples, uint32_t frames, uint64_t source_start, double capture_end_host_seconds);
uint64_t ls_rendered_source_frame(LSCore * _Null_unspecified core);
uint64_t ls_rendered_capture_nanos(LSCore * _Null_unspecified core);
uint64_t ls_rendered_host_nanos(LSCore * _Null_unspecified core);
float ls_rendered_stem_weight(LSCore * _Null_unspecified core);
uint32_t ls_read_mix(LSCore * _Null_unspecified core, float * _Null_unspecified samples, uint32_t frames);
void ls_reset(LSCore * _Null_unspecified core);
void ls_enable(LSCore * _Null_unspecified core, int enabled);
// Changes the mix on the queued timeline. It never resets or flushes playback.
void ls_stems(LSCore * _Null_unspecified core, int enabled);
void ls_controls(LSCore * _Null_unspecified core, const float * _Null_unspecified gains, uint32_t mute, uint32_t solo);
uint64_t ls_played(LSCore * _Null_unspecified core);
uint64_t ls_underruns(LSCore * _Null_unspecified core);
uint64_t ls_overflows(LSCore * _Null_unspecified core);
uint32_t ls_queued(LSCore * _Null_unspecified core);
void ls_flush_output(LSCore * _Null_unspecified core);
// Returns 1 for a match, 0 for a mismatch, -1 for inconclusive silence.
void ls_render(LSCore * _Null_unspecified core, uint32_t frames, AudioBufferList * _Null_unspecified output);
void ls_render_timed(LSCore * _Null_unspecified core, uint32_t frames, AudioBufferList * _Null_unspecified output, const AudioTimeStamp * _Nullable time);
OSStatus ls_capture_callback(AudioDeviceID device, const AudioTimeStamp * _Nonnull now, const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull input_time, AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull output_time, void * _Nullable context);
