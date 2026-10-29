#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
cat > "$task_tmp/test.c" <<'C'
#include "AudioCore.c"
#include <assert.h>
int main(void){
 LSCore *c=ls_create(8000,8000);assert(c);ls_enable(c,1);
 assert(!ls_controls_counted(c,0,5,0,0));assert(!ls_take_meters_counted(c,0,5));assert(!ls_output_write_timed_counted(c,0,1,5,0,0));
 float four[4400]={0},six[6000]={0},out[800];
 for(int i=0;i<400;i++){four[i*11+8]=.4f;four[i*11+9]=.4f;four[i*11+10]=1;six[i*15+8]=.2f;six[i*15+9]=.2f;six[i*15+10]=.3f;six[i*15+11]=.3f;six[i*15+12]=.5f;six[i*15+13]=.5f;six[i*15+14]=1;}
 assert(ls_output_write(c,four,400)==400);assert(ls_output_write_timed_counted(c,six,400,6,1000,2)==400);
 float g[6]={1,1,1,1,1,1};ls_controls_counted(c,g,6,0,16);
 assert(ls_read_mix(c,out,400)==400);assert(fabsf(out[798]-.4f)<.0001f);
 assert(ls_read_mix(c,out,400)==400);assert(fabsf(out[798]-.2f)<.001f);
 float peaks[7]={0};peaks[6]=123;assert(ls_take_meters_counted(c,peaks,6));assert(peaks[4]==.2f && peaks[5]==.3f && peaks[6]==123);
 ls_controls_counted(c,g,6,32,32);assert(ls_output_write_timed_counted(c,six,400,6,2000,3)==400);ls_read_mix(c,out,400);assert(fabsf(out[798])<.001f);
 ls_flush_output(c);assert(ls_queued(c)==0);ls_reset(c);assert(ls_queued(c)==0);
 assert(!ls_output_write_timed_counted(c,six,c->output.capacity+1,6,0,0));
 float legacy[5]={0,0,0,0,123};ls_take_meters(c,legacy);assert(legacy[4]==123);ls_destroy(c);return 0;
}
C
clang -w -fsanitize=address,undefined -I Sources/AudioCore -I Sources/AudioCore/include "$task_tmp/test.c" -framework CoreAudio -o "$task_tmp/test"
"$task_tmp/test"
echo 'Native count checks passed'
