// Use upstream's supported single-unit build with the same resampler as the
// listening-approved CLI. All dependencies are linked into the app.
#define ALREADY_CONFIGURED 1
#define HAVE_LIBSAMPLERATE 1
#define HAVE_VDSP 1
#define NO_TIMING 1
#define NO_THREADING 1
#define NO_THREAD_CHECKS 1
#include "vendor/rubberband-4.0.0/single/RubberBandSingle.cpp"
