#include "PitchCore.h"
#include "vendor/rubberband-4.0.0/rubberband/RubberBandStretcher.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <memory>

namespace {
using Stretcher = RubberBand::RubberBandStretcher;
constexpr size_t capacity = 65536, chunkSize = 512, reserve = 2048;
struct QuietLog : Stretcher::Logger {
    void log(const char *) override {}
    void log(const char *, double) override {}
    void log(const char *, double, double) override {}
};
}
struct LSPitch {
    std::atomic<int> requested{0};
    std::atomic<uint32_t> latency{0};
    std::atomic<bool> failed{false};
    Stretcher stretcher;
    int current = 0;
    std::array<float, capacity> left{}, right{};
    std::array<float, chunkSize> scratchL{}, scratchR{}, zero{};
    size_t head = 0, queued = 0, discard = 0, silence = 0;
    bool ready = false;
    explicit LSPitch(double rate) : stretcher(size_t(rate), 2, std::make_shared<QuietLog>(),
        Stretcher::OptionProcessRealTime | Stretcher::OptionEngineFiner |
        Stretcher::OptionPitchHighQuality | Stretcher::OptionChannelsTogether, 1, 1) {
        stretcher.setMaxProcessSize(chunkSize);
    }
    void drain() {
        while (stretcher.available() > 0) {
            float *out[2] = {scratchL.data(), scratchR.data()};
            size_t n = stretcher.retrieve(out, std::min(chunkSize, size_t(stretcher.available())));
            for (size_t i = 0; i < n; ++i) {
                if (discard) { --discard; continue; }
                if (queued == capacity) { failed.store(true, std::memory_order_relaxed); return; }
                size_t at = (head + queued++) % capacity;
                left[at] = scratchL[i]; right[at] = scratchR[i];
            }
        }
    }
    void reset() {
        stretcher.reset();
        head = queued = silence = 0;
        failed.store(false, std::memory_order_relaxed);
        ready = false;
        current = requested.load(std::memory_order_relaxed);
        stretcher.setPitchScale(std::pow(2., current / 12.));
        discard = stretcher.getStartDelay();
        latency.store(0, std::memory_order_relaxed);
        if (current) {
            const float *input[2] = {zero.data(), zero.data()};
            size_t pad = stretcher.getPreferredStartPad();
            while (pad) {
                size_t n = std::min(pad, chunkSize);
                stretcher.process(input, n, false);
                drain();
                pad -= n;
            }
        }
    }
};
extern "C" {
LSPitch *ls_pitch_create(double rate) {
    if (!std::isfinite(rate) || rate < 8000 || rate > 192000) return nullptr;
    try { return new LSPitch(rate); } catch (...) { return nullptr; }
}
void ls_pitch_destroy(LSPitch *pitch) { delete pitch; }
void ls_pitch_set(LSPitch *pitch, int semitones) {
    if (pitch && semitones >= -12 && semitones <= 12)
        pitch->requested.store(semitones, std::memory_order_relaxed);
}
void ls_pitch_reset(LSPitch *pitch) {
    if (!pitch) return;
    try { pitch->reset(); }
    catch (...) { pitch->failed.store(true, std::memory_order_relaxed); }
}
int ls_pitch_failed(LSPitch *pitch) { return pitch && pitch->failed.load(std::memory_order_relaxed); }
uint32_t ls_pitch_latency(LSPitch *pitch) { return pitch ? pitch->latency.load(std::memory_order_relaxed) : 0; }
void ls_pitch_process(LSPitch *p, float *left, float *right, uint32_t frames) {
    if (!p || !left || !right) return;
    try {
        const int target = p->requested.load(std::memory_order_relaxed);
        if (target != p->current) {
            if (target == 0 || p->current == 0) p->reset();
            else { p->stretcher.setPitchScale(std::pow(2., target / 12.)); p->current = target; }
        }
        if (!p->current) return; // Exact zero bypass: no buffering or sample conversion.
        for (size_t offset = 0; offset < frames; offset += chunkSize) {
            size_t n = std::min(size_t(frames) - offset, chunkSize);
            const float *input[2] = {left + offset, right + offset};
            p->stretcher.process(input, n, false);
            p->drain();
            if (!p->ready && p->queued >= reserve) p->ready = true;
            for (size_t i = 0; i < n; ++i) {
                if (p->ready && p->queued) {
                    left[offset+i] = p->left[p->head]; right[offset+i] = p->right[p->head];
                    p->head = (p->head+1)%capacity; --p->queued;
                } else {
                    left[offset+i] = right[offset+i] = 0;
                    if (p->ready) p->failed.store(true, std::memory_order_relaxed);
                    ++p->silence;
                }
            }
            p->latency.store(uint32_t(p->silence), std::memory_order_relaxed);
        }
    } catch (...) {
        p->failed.store(true, std::memory_order_relaxed);
        std::fill(left, left + frames, 0);
        std::fill(right, right + frames, 0);
    }
}
}
