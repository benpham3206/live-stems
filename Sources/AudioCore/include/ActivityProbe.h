#ifndef LS_ACTIVITY_PROBE_H
#define LS_ACTIVITY_PROBE_H
#include <CoreAudio/CoreAudio.h>
typedef struct LSActivityPeak LSActivityPeak;
LSActivityPeak * _Nullable ls_activity_create(void);
void ls_activity_destroy(LSActivityPeak * _Nonnull peak);
int ls_activity_check(void);
float ls_activity_take(LSActivityPeak * _Nonnull peak);
OSStatus ls_activity_callback(AudioDeviceID device, const AudioTimeStamp * _Nonnull now, const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull input_time, AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull output_time, void * _Nullable context);
#endif
