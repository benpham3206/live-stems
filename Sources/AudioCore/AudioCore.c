#include "AudioCore.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <CoreAudio/HostTime.h>
typedef struct { float *data; uint32_t capacity, channels; atomic_ullong read, write; } Ring;
struct LSCore {
    Ring capture, output;
    atomic_int enabled, stems;
    atomic_uint gains[4], mute, solo;
    atomic_ullong epoch, played, underruns, overflows;
    float smooth[4], stem_blend;
    double rate, capture_rate;
    uint64_t *capture_times, *output_times, *output_frames;
    atomic_ullong rendered_frame, rendered_capture, rendered_host;
    atomic_uint rendered_weight;
    atomic_ullong trace_sequence;
    LSRenderSnapshot render_trace;
    atomic_ullong flush;
    atomic_ullong flush_sequence;
    atomic_uint flush_fade;
    uint64_t render_epoch, applied_flush, fade_mark;
    uint32_t fade_total, fade_done;
    float last_left, last_right, envelope;
    int priming, fade_out;
    float meter_hold[4];
    atomic_uint meter[4];
};
static void init_ring(Ring *r, uint32_t n, uint32_t ch) { r->capacity=n; r->channels=ch; r->data=calloc((size_t)n*ch,sizeof(float)); }
LSCore *ls_create(double cr, double rr) {
    if(cr<8000 || cr>192000 || rr<8000 || rr>192000) return NULL;
    LSCore *c=calloc(1,sizeof(*c)); if(!c)return NULL;
    init_ring(&c->capture,(uint32_t)(cr*24),2); init_ring(&c->output,(uint32_t)(rr*24),11); c->rate=rr; c->capture_rate=cr; c->capture_times=calloc((size_t)(cr*24),sizeof(uint64_t));
    c->output_times=calloc(c->output.capacity,sizeof(uint64_t)); c->output_frames=calloc(c->output.capacity,sizeof(uint64_t)); atomic_store(&c->rendered_frame,UINT64_MAX); c->render_trace.source_frame=UINT64_MAX;
    if(!c->output_times || !c->output_frames || !c->capture.data || !c->output.data || !c->capture_times) {ls_destroy(c);return NULL;}
    float gains[4]={1,1,1,1}; ls_controls(c,gains,0,0); for(int s=0;s<4;s++)c->smooth[s]=1; atomic_store(&c->stems,1); c->stem_blend=1; c->priming=1; return c;
}
void ls_destroy(LSCore *c) { if(c){free(c->capture.data);free(c->output.data);free(c->capture_times);free(c->output_times);free(c->output_frames);free(c);} }
void ls_enable(LSCore *c,int enabled){atomic_store(&c->enabled,enabled);}
void ls_stems(LSCore *c,int enabled){atomic_store(&c->stems,enabled!=0);}
void ls_reset(LSCore *c){atomic_store(&c->enabled,0);atomic_fetch_add(&c->epoch,1);ls_discard_capture(c);atomic_store(&c->output.read,atomic_load(&c->output.write));atomic_store(&c->played,0);}
void ls_controls(LSCore *c,const float *g,uint32_t mute,uint32_t solo){for(int s=0;s<4;s++){uint32_t bits;float v=fmaxf(0,fminf(1,g[s]));memcpy(&bits,&v,4);atomic_store(&c->gains[s],bits);}atomic_store(&c->mute,mute);atomic_store(&c->solo,solo);}
// The consumer owns read. A producer flush requests a boundary, so a callback
// already in flight cannot publish an old read index over a new one.
void ls_flush_output_faded(LSCore *c,uint32_t fade_frames){atomic_store(&c->flush_fade,fade_frames);atomic_store(&c->flush,atomic_load(&c->output.write));atomic_fetch_add(&c->flush_sequence,1);}
void ls_flush_output(LSCore *c){ls_flush_output_faded(c,0);}
uint64_t ls_played(LSCore *c){return atomic_load(&c->played);}
uint64_t ls_underruns(LSCore *c){return atomic_load(&c->underruns);}
uint64_t ls_overflows(LSCore *c){return atomic_load(&c->overflows);}
// Frames before a pending flush point will never play, so they are not queued.
uint32_t ls_queued(LSCore *c){uint64_t r=atomic_load(&c->output.read),f=atomic_load(&c->flush);if(f>r)r=f;return (uint32_t)(atomic_load(&c->output.write)-r);}
uint32_t ls_capture_read_timed(LSCore *c,float *out,uint32_t n,double *end_host_seconds){Ring *r=&c->capture;uint64_t pos=atomic_load(&r->read),end=atomic_load(&r->write);if(n>end-pos)n=(uint32_t)(end-pos);for(uint32_t i=0;i<n;i++)memcpy(out+i*2,r->data+((pos+i)%r->capacity)*2,8);if(n && end_host_seconds){uint64_t stamp=c->capture_times[(pos+n-1)%r->capacity];*end_host_seconds=stamp?(double)stamp/1e9+1.0/c->capture_rate:0;}atomic_store(&r->read,pos+n);return n;}
uint32_t ls_capture_read(LSCore *c,float *out,uint32_t n){return ls_capture_read_timed(c,out,n,NULL);}
// Advance past one empty slot to invalidate the position held by an in-flight
// producer. CAS publication below makes the cut and callback commit atomic.
// The empty slot is discarded immediately; it never enters the source clock.
void ls_discard_capture(LSCore *c){uint64_t boundary=atomic_fetch_add(&c->capture.write,1)+1;atomic_store(&c->capture.read,boundary);}
// Publish once per callback; no encoding, allocation, locks, or file I/O.
static void publish_trace(LSCore *c){
    atomic_fetch_add(&c->trace_sequence,1);
    atomic_store(&c->rendered_frame,c->render_trace.source_frame);
    atomic_store(&c->rendered_capture,c->render_trace.capture_nanos);
    atomic_store(&c->rendered_host,c->render_trace.render_nanos);
    uint32_t bits;memcpy(&bits,&c->render_trace.stem_weight,4);atomic_store(&c->rendered_weight,bits);
    atomic_fetch_add(&c->trace_sequence,1);
}
// Pre-fader stem peaks since the last take. Non-negative float bits sort like
// unsigned integers, so a CAS max needs no lock on the render thread.
static void publish_meters(LSCore *c){
    for(int s=0;s<4;s++){
        uint32_t bits;memcpy(&bits,&c->meter_hold[s],4);c->meter_hold[s]=0;
        uint32_t seen=atomic_load(&c->meter[s]);
        while(bits>seen && !atomic_compare_exchange_weak(&c->meter[s],&seen,bits)){}
    }
}
void ls_take_meters(LSCore *c,float *peaks){for(int s=0;s<4;s++){uint32_t bits=atomic_exchange(&c->meter[s],0);memcpy(&peaks[s],&bits,4);}}
int ls_render_snapshot(LSCore *c,LSRenderSnapshot *out){
    for(int attempt=0;attempt<4;attempt++){
        uint64_t before=atomic_load(&c->trace_sequence);if(before&1)continue;
        LSRenderSnapshot value={atomic_load(&c->rendered_frame),atomic_load(&c->rendered_capture),atomic_load(&c->rendered_host),ls_rendered_stem_weight(c)};
        if(before==atomic_load(&c->trace_sequence)){*out=value;return 1;}
    }return 0;
}
uint64_t ls_rendered_source_frame(LSCore *c){return atomic_load(&c->rendered_frame);}
uint64_t ls_rendered_capture_nanos(LSCore *c){return atomic_load(&c->rendered_capture);}
uint64_t ls_rendered_host_nanos(LSCore *c){return atomic_load(&c->rendered_host);}
float ls_rendered_stem_weight(LSCore *c){uint32_t bits=atomic_load(&c->rendered_weight);float value;memcpy(&value,&bits,4);return value;}
uint32_t ls_output_write(LSCore *c,const float *data,uint32_t n){return ls_output_write_timed(c,data,n,UINT64_MAX,0);}
uint32_t ls_output_write_timed(LSCore *c,const float *data,uint32_t n,uint64_t source_start,double capture_end_host_seconds){Ring *r=&c->output;uint64_t pos=atomic_load(&r->write),read=atomic_load(&r->read);if(n>r->capacity-(pos-read)){atomic_fetch_add(&c->overflows,1);return 0;}for(uint32_t i=0;i<n;i++){uint64_t slot=(pos+i)%r->capacity;memcpy(r->data+slot*11,data+i*11,44);c->output_frames[slot]=source_start==UINT64_MAX?UINT64_MAX:source_start+i;c->output_times[slot]=capture_end_host_seconds>0?(uint64_t)((capture_end_host_seconds-(double)(n-i)/c->rate)*1e9):0;}atomic_store(&r->write,pos+n);return n;}
static int next_frame(LSCore *c,float *left,float *right){
    *left=*right=0; if(!atomic_load(&c->enabled))return 0;
    uint64_t epoch=atomic_load(&c->epoch);
    if(epoch!=c->render_epoch){c->render_epoch=epoch;c->last_left=c->last_right=c->envelope=0;c->stem_blend=atomic_load(&c->stems)?1:0;c->priming=1;c->fade_out=0;c->fade_total=0;}
    Ring *r=&c->output;uint64_t pos=atomic_load(&r->read);
    uint64_t sequence=atomic_load(&c->flush_sequence);
    uint64_t flush=atomic_load(&c->flush);
    uint64_t end=atomic_load(&r->write);
    if(sequence!=c->applied_flush){
        c->applied_flush=sequence;
        uint32_t fade=atomic_load(&c->flush_fade);
        // A faded flush plays the queue before the flush point under a fade,
        // as Spotify fades a pause or skip, and jumps when the fade ends.
        if(fade && flush>pos && !c->priming){
            if(!c->fade_total){c->fade_total=fade;c->fade_done=0;}
            c->fade_mark=flush;
        }else{
            c->fade_total=0;
            if(flush>pos){pos=flush;atomic_store(&r->read,pos);}
            // Keep the last rendered sample and fade it over ~2 ms. The queue
            // is already gone, so this only softens the cut edge, never audio.
            c->priming=1;c->envelope=0;c->fade_out=96;
            c->render_trace=(LSRenderSnapshot){.source_frame=UINT64_MAX};
        }
    }
    if(c->fade_total && (pos>=c->fade_mark || c->fade_done>=c->fade_total)){
        if(c->fade_mark>pos){pos=c->fade_mark;atomic_store(&r->read,pos);}
        c->fade_total=0;c->priming=1;c->envelope=0;c->fade_out=0;c->last_left=c->last_right=0;
        c->render_trace=(LSRenderSnapshot){.source_frame=UINT64_MAX};
    }
    uint32_t prime=(uint32_t)(c->rate*.05);
    if(pos==end || (c->priming && end-pos<prime)){
        if(!c->priming){atomic_fetch_add(&c->underruns,1);c->priming=1;c->envelope=0;c->fade_out=0;}
        if(c->fade_out>0){
            float gain=(float)(c->fade_out-1)/96.0f;
            *left=c->last_left*gain;*right=c->last_right*gain;
            if(--c->fade_out==0)c->last_left=c->last_right=0;
            return 0;
        }
        c->last_left*=.98f;c->last_right*=.98f;
        if(fabsf(c->last_left)<1e-7f)c->last_left=0;
        if(fabsf(c->last_right)<1e-7f)c->last_right=0;
        *left=c->last_left;*right=c->last_right;return 0;
    }
    c->priming=0;c->fade_out=0;c->envelope=fminf(1,c->envelope+(float)(1.0/(c->rate*.0025)));
    float *f=r->data+(pos%r->capacity)*11;uint32_t mute=atomic_load(&c->mute),solo=atomic_load(&c->solo);
    float blend_target=atomic_load(&c->stems)?1:0;
    c->stem_blend+=fmaxf(-(float)(1.0/(c->rate*.008)),fminf((float)(1.0/(c->rate*.008)),blend_target-c->stem_blend));
    float weight=fmaxf(0,fminf(1,f[10]))*c->stem_blend;
    c->render_trace.stem_weight=weight;
    float raw_left=0,raw_right=0;int uniform=1;
    for(int s=0;s<4;s++){
        uint32_t bits=atomic_load(&c->gains[s]);float target;memcpy(&target,&bits,4);
        if((mute&(1u<<s)) || (solo && !(solo&(1u<<s))))target=0;
        c->smooth[s]+=(target-c->smooth[s])*(float)(1.0/(c->rate*.008));
        if(fabsf(target-c->smooth[s])<1e-5f)c->smooth[s]=target;
        if(c->smooth[s]!=c->smooth[0])uniform=0;
        raw_left+=f[s*2];raw_right+=f[s*2+1];
        *left+=f[s*2]*c->smooth[s];*right+=f[s*2+1]*c->smooth[s];
    }
    // Assign mixture residual to Other. Equal gains need no stems: the mix is
    // Original at that gain (neutral is Original, all-stem mute is silence),
    // so it also holds while the model rests and stem weight is zero.
    *left+=(f[8]-raw_left)*c->smooth[3];*right+=(f[9]-raw_right)*c->smooth[3];
    for(int s=0;s<4;s++){
        float l=f[s*2],r=f[s*2+1];if(s==3){l+=f[8]-raw_left;r+=f[9]-raw_right;}
        c->meter_hold[s]=fmaxf(c->meter_hold[s],fmaxf(fabsf(l),fabsf(r))*weight);
    }
    // Equal gains need no stems: the fallback below is then exact (Original at
    // that gain), and Original mode still ignores the controls.
    if(uniform)weight=0;
    float ceiling=fmaxf(.98f,fmaxf(fabsf(f[8]),fabsf(f[9])));
    float peak=fmaxf(fabsf(*left),fabsf(*right));if(peak>ceiling){float gain=ceiling/peak;*left*=gain;*right*=gain;}
    // Missing stems keep only the stem-free part of the mix: Original at
    // Other's gain. Original mode (stem_blend 0) still ignores the controls.
    float fallback=c->stem_blend*c->smooth[3]+(1-c->stem_blend);
    *left=(*left*weight+f[8]*fallback*(1-weight))*c->envelope;
    *right=(*right*weight+f[9]*fallback*(1-weight))*c->envelope;
    // Spotify's fade shape, measured with skip-probe: gain (1 - t/T)^4.
    if(c->fade_total){float t=1-(float)c->fade_done++/(float)c->fade_total,g=t*t*t*t;*left*=g;*right*=g;}
    c->last_left=*left;c->last_right=*right;
    c->render_trace.source_frame=c->output_frames[pos%r->capacity];c->render_trace.capture_nanos=c->output_times[pos%r->capacity];
    atomic_store(&r->read,pos+1);atomic_fetch_add(&c->played,1);return 1;
}
uint32_t ls_read_mix(LSCore *c,float *out,uint32_t n){uint32_t got=0;uint64_t epoch=atomic_load(&c->epoch);for(uint32_t i=0;i<n;i++){float l=0,r=0;if(epoch==atomic_load(&c->epoch))got+=next_frame(c,&l,&r);out[i*2]=l;out[i*2+1]=r;}publish_trace(c);publish_meters(c);return got;}
void ls_render(LSCore *c,uint32_t n,AudioBufferList *out){ls_render_timed(c,n,out,NULL);}
void ls_render_timed(LSCore *c,uint32_t n,AudioBufferList *out,const AudioTimeStamp *time){uint64_t host=(time && (time->mFlags & kAudioTimeStampHostTimeValid))?AudioConvertHostTimeToNanos(time->mHostTime):0;uint64_t epoch=atomic_load(&c->epoch);for(uint32_t i=0;i<n;i++){float l=0,r=0;if(epoch==atomic_load(&c->epoch) && next_frame(c,&l,&r) && host)c->render_trace.render_nanos=host+(uint64_t)(i*1e9/c->rate);if(out->mNumberBuffers==1){float *p=out->mBuffers[0].mData;if(p){p[i*2]=l;p[i*2+1]=r;}}else if(out->mNumberBuffers>=2){float *a=out->mBuffers[0].mData,*b=out->mBuffers[1].mData;if(a)a[i]=l;if(b)b[i]=r;}}publish_trace(c);publish_meters(c);}
OSStatus ls_capture_callback(AudioDeviceID d,const AudioTimeStamp *now,const AudioBufferList *in,const AudioTimeStamp *it,AudioBufferList *out,const AudioTimeStamp *ot,void *context){
    LSCore *c=context;if(!c || !in || !in->mNumberBuffers)return noErr;uint64_t epoch=atomic_load(&c->epoch);Ring *r=&c->capture;
    int planar=in->mNumberBuffers==2 && in->mBuffers[0].mNumberChannels==1 && in->mBuffers[1].mNumberChannels==1;
    if(!planar && !(in->mNumberBuffers==1 && in->mBuffers[0].mNumberChannels==2))return noErr;
    uint32_t n=in->mBuffers[0].mDataByteSize/(planar?4:8);uint64_t pos=atomic_load(&r->write),read=atomic_load(&r->read);
    if(planar && in->mBuffers[1].mDataByteSize/4<n)return noErr;
    if(n>r->capacity-(pos-read)){atomic_fetch_add(&c->overflows,1);return noErr;}
    const float *a=in->mBuffers[0].mData,*b=planar?in->mBuffers[1].mData:NULL;if(!a || (planar && !b))return noErr;
    const uint64_t host=(it && (it->mFlags & kAudioTimeStampHostTimeValid))?AudioConvertHostTimeToNanos(it->mHostTime):0;
    for(uint32_t i=0;i<n;i++){float *p=r->data+((pos+i)%r->capacity)*2;p[0]=a[planar?i:i*2];p[1]=planar?b[i]:a[i*2+1];c->capture_times[(pos+i)%r->capacity]=host?host+(uint64_t)((double)i/c->capture_rate*1e9):0;}
    if(epoch==atomic_load(&c->epoch))atomic_compare_exchange_strong(&r->write,&pos,pos+n);return noErr;
}
