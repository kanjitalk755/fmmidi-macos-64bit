#import "MyController.h"

#include <AudioUnit/AudioUnit.h>

#include "filter.hpp"
#include "midisynth.hpp"
#include "sequencer.hpp"

#include <complex>
#include <cerrno>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>

static MyView* view;
static midisynth::fm_note_factory note_factory;
static midisynth::synthesizer synthesizer(&note_factory);
static midisequencer::sequencer sequencer;
static filter::finite_impulse_response equalizer_left;
static filter::finite_impulse_response equalizer_right;
static std::map<double, double> equalizer_gains;
static bool equalizer_enabled;
static NSConditionLock* lock;
static double sequencer_time;
static bool mute[16];
static int solo = -1;
static int bpm = 120;
static int note_count;
static float sampling_rate = 44100;
static float system_sampling_rate;
static int_least32_t last_512samples[1024];
static bool no_spectrum;
static bool seeking;

enum lock_condition_t{
    LOCK_CONDITION_INITIALIZING,
    LOCK_CONDITION_READY,
    LOCK_CONDITION_STATUSCHANGED,
    LOCK_CONDITION_TERMINATED
};

static enum thread_status_t{
    STATUS_TERMINATING,
    STATUS_STOPPED,
    STATUS_PLAYING
}status = STATUS_STOPPED;

static const char* program_names[128] = {
    "Grand Piano",
    "Bright Piano",
    "Electric Grand Piano",
    "Honky Tonk",
    "Electric Piano 1",
    "Electric Piano 2",
    "Harpsichord",
    "Clavinet",
    "Celesta",
    "Glockenspiel",
    "Music Box",
    "Vibraphone",
    "Marimba",
    "Xylophone",
    "Tubular Bell",
    "Dulcimer",
    "Drawbar Organ",
    "Percussive Organ",
    "Rock Organ",
    "Church Organ",
    "Reed Organ",
    "Accordion",
    "Harmonica",
    "Bandoneon",
    "Nylon Strings Guitar",
    "Steel Strings Guitar",
    "Guitar/Jazz",
    "Guitar/Clean",
    "Guitar/Muted",
    "Guitar/Overdriven",
    "Guitar/Distortion",
    "Guitar Harmonics",
    "Acoustic Bass",
    "Fingered Bass",
    "Picked Bass",
    "Fretless Bass",
    "Slap Bass 1",
    "Slap Bass 2",
    "Synth Bass 1",
    "Synth Bass 2",
    "Violin",
    "Viola",
    "Cello",
    "Contrabass",
    "Tremolo Strings",
    "Pizzicato Strings",
    "Harp",
    "Timpani",
    "Strings",
    "Slow Strings",
    "Synth Strings 1",
    "Synth Strings 2",
    "Choir Aahs",
    "Voice Oohs",
    "Synth Vox",
    "Orchestra Hit",
    "Trumpet",
    "Trombone",
    "Tuba",
    "Muted Trumpet",
    "French Horn",
    "Brass",
    "Synth Brass 1",
    "Synth Brass 2",
    "Soprano Sax",
    "Alto Sax",
    "Tenor Sax",
    "Baritone Sax",
    "Oboe",
    "English Horn",
    "Bassoon",
    "Clarinet",
    "Piccolo",
    "Flute",
    "Recorder",
    "Pan Flute",
    "Blown Bottle",
    "Shakuhachi",
    "Whistle",
    "Ocarina",
    "Square Wave",
    "Sawtooth Wave",
    "Synth Calliope",
    "Chiffer Lead",
    "Charang",
    "Solo Vox",
    "5th Lead",
    "Bass&Lead",
    "Fantasia",
    "Warm Pad",
    "Polysynth",
    "Space choir",
    "Bowed Glass",
    "Metal Pad",
    "Halo Pad",
    "Sweep Pad",
    "Ice Rain",
    "Soundtrack",
    "Crystal",
    "Atmosphere",
    "Brightness",
    "Goblin",
    "Echo Drops",
    "Sci-Fi",
    "Sitar",
    "Banjo",
    "Shamisen",
    "Koto",
    "Kalimba",
    "Bag Pipe",
    "Fiddle",
    "Shanai",
    "Tinkle Bell",
    "Agogo",
    "Steel Drums",
    "Woodblock",
    "Taiko",
    "Melodic Tom",
    "Synth Drum",
    "Reverse Cymbal",
    "Guitar Fret Noise",
    "Breath Noise",
    "Seashore",
    "Bird Tweet",
    "Telephone Ring",
    "Helicopter",
    "Applause",
    "Gun Shot"
};

static AudioUnit audioUnit;
static std::vector<int_least32_t> mixing_buffer;

static OSStatus audio_render_callback(void* inRefCon, AudioUnitRenderActionFlags* ioActionFlags, const AudioTimeStamp* inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList* ioData)
{
    std::size_t output_samples = inNumberFrames;
    if(output_samples){
        float* ch1 = (float*)ioData->mBuffers[0].mData;
        float* ch2 = (float*)ioData->mBuffers[1].mData;
        [lock lock];
        std::size_t samples = static_cast<std::size_t>(output_samples * sampling_rate / system_sampling_rate);
        mixing_buffer.resize(samples * 2);
        std::memset(&mixing_buffer[0], 0, mixing_buffer.size() * sizeof(int_least32_t));
        int note = synthesizer.synthesize_mixing(&mixing_buffer[0], samples, sampling_rate);
        if(note && equalizer_enabled){
            equalizer_left.apply(&mixing_buffer[0], &mixing_buffer[0], samples, sizeof(int_least32_t[2]));
            equalizer_right.apply(&mixing_buffer[1], &mixing_buffer[1], samples, sizeof(int_least32_t[2]));
        }
        [lock unlock];
        if(note != note_count){
            note_count = note;
            no_spectrum = false;
        }
        if(samples < 512){
            std::memmove(&last_512samples[0], &last_512samples[samples * 2], sizeof(int_least32_t) * (1024 - samples * 2));
            std::memcpy(&last_512samples[1024 - samples * 2], &mixing_buffer[0], sizeof(int_least32_t) * samples * 2);
        }else{
            std::memcpy(&last_512samples[0], &mixing_buffer[samples * 2 - 1024], sizeof(int_least32_t) * 1024);
        }
        if(!note){
            for(std::size_t i = 0; i < output_samples; ++i){
                ch1[i] = 0;
                ch2[i] = 0;
            }
        }else if(samples == output_samples){
            for(std::size_t i = 0; i < samples; ++i){
                ch1[i] = mixing_buffer[i * 2 + 0] / 32768.0f;
                ch2[i] = mixing_buffer[i * 2 + 1] / 32768.0f;
            }
        }else{
            std::size_t d = (samples << 10) / output_samples;
            for(std::size_t i = 0, j = 0; i < output_samples; ++i, j += d){
                std::size_t n = j >> 10;
                ch1[i] = mixing_buffer[n * 2 + 0] / 32768.0f;
                ch2[i] = mixing_buffer[n * 2 + 1] / 32768.0f;
            }
        }
    }
    return 0;
}

static bool initialize_audio(void)
{
    AURenderCallbackStruct callback = { audio_render_callback, NULL };
    AudioStreamBasicDescription format;
	AudioComponentDescription desc = {
		.componentType = kAudioUnitType_Output,
		.componentSubType = kAudioUnitSubType_DefaultOutput,
	};
	AudioComponentInstanceNew(AudioComponentFindNext(NULL, &desc), &audioUnit);
    if(audioUnit){
        if(!AudioUnitInitialize(audioUnit)){
            UInt32 size = sizeof(format);
            if(!AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size)){
                system_sampling_rate = format.mSampleRate;
                NSLog(@"system_sampling_rate: %f", system_sampling_rate);
                format.mFormatID = kAudioFormatLinearPCM;
                format.mFormatFlags = kAudioFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked;
                format.mBytesPerPacket = sizeof(float[2]);
                format.mFramesPerPacket = 1;
                format.mBytesPerFrame = sizeof(float[2]);
                format.mChannelsPerFrame = 2;
                format.mBitsPerChannel = sizeof(float) * CHAR_BIT;
                if(!AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Global, 0, &format, sizeof(format))
                && !AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &callback, sizeof(callback))
                && !AudioOutputUnitStart(audioUnit)){
                    return true;
                }
            }
            AudioUnitUninitialize(audioUnit);
        }
        CloseComponent(audioUnit);
        audioUnit = 0;
    }
    return false;
}

static void finalize_audio(void)
{
    if(audioUnit){
        AudioUnitUninitialize(audioUnit);
        CloseComponent(audioUnit);
    }
}

static void apply_mute(void)
{
    char s[64];
    for(int i = 0; i < 16; ++i){
        if(solo == i){
            synthesizer.get_channel(i)->set_mute(false);
        }else if(solo == -1 && !mute[i]){
            synthesizer.get_channel(i)->set_mute(false);
        }else{
            synthesizer.get_channel(i)->set_mute(true);
        }
        std::sprintf(s, "ch%d-mute", i + 1);
        [view setValue:mute[i] forKey:s type:UI_HORIZONTAL];
        std::sprintf(s, "ch%d-solo", i + 1);
        [view setValue:solo == i forKey:s type:UI_HORIZONTAL];
    }
}

static void update_note(int ch, int note, bool on)
{
    char s[64];
    std::sprintf(s, "ch%d-key%d", ch + 1, note);
    [view setValue:on forKey:s type:UI_HORIZONTAL];
}

static void update_controls(int ch)
{
    char s[64];
    std::sprintf(s, "ch%d-damper", ch + 1);
    [view setValue:synthesizer.get_channel(ch)->get_damper() > 0 forKey:s type:UI_HORIZONTAL];
    std::sprintf(s, "ch%d-sostenute", ch + 1);
    [view setValue:synthesizer.get_channel(ch)->get_sostenute() > 0 forKey:s type:UI_HORIZONTAL];
    std::sprintf(s, "ch%d-freeze", ch + 1);
    [view setValue:synthesizer.get_channel(ch)->get_freeze() > 0 forKey:s type:UI_HORIZONTAL];
    std::sprintf(s, "ch%d-pan", ch + 1);
    [view setValue:synthesizer.get_channel(ch)->get_panpot() / 16384.0 forKey:s type:UI_HORIZONTAL_CENTER];
    std::sprintf(s, "ch%d-volume", ch + 1);
    [view setValue:synthesizer.get_channel(ch)->get_volume() / 16384.0 forKey:s type:UI_HORIZONTAL];
    std::sprintf(s, "ch%d-expression", ch + 1);
    [view setValue:synthesizer.get_channel(ch)->get_expression() / 16384.0 forKey:s type:UI_HORIZONTAL];
    std::sprintf(s, "ch%d-pitchbend", ch + 1);
    [view setValue:synthesizer.get_channel(ch)->get_pitch_bend() / 16384.0 forKey:s type:UI_HORIZONTAL_CENTER];
    std::sprintf(s, "ch%d-pitchbendsensitivity", ch + 1);
    [view setValue:synthesizer.get_channel(ch)->get_pitch_bend_sensitivity() / 16384.0 forKey:s type:UI_HORIZONTAL];
    std::sprintf(s, "ch%d-channelpressure", ch + 1);
    [view setValue:synthesizer.get_channel(ch)->get_channel_pressure() / 128.0 forKey:s type:UI_HORIZONTAL];
    std::sprintf(s, "ch%d-modulationdepth", ch + 1);
    [view setValue:synthesizer.get_channel(ch)->get_modulation_depth() / 16384.0 forKey:s type:UI_HORIZONTAL];
    std::sprintf(s, "ch%d-modulationdepthrange", ch + 1);
    [view setValue:synthesizer.get_channel(ch)->get_modulation_depth_range() / 16384.0 forKey:s type:UI_HORIZONTAL];
    std::sprintf(s, "ch%d-finetuning", ch + 1);
    [view setValue:synthesizer.get_channel(ch)->get_fine_tuning() / 16384.0 forKey:s type:UI_HORIZONTAL_CENTER];
    std::sprintf(s, "ch%d-coarsetuning", ch + 1);
    [view setValue:synthesizer.get_channel(ch)->get_coarse_tuning() / 16384.0 forKey:s type:UI_HORIZONTAL_CENTER];
}

static void update_program(int ch)
{
    int program = synthesizer.get_channel(ch)->get_program();
    bool drum = (program >> 14) == 120;
    char s[64];
    const char* name;
    if(drum){
        name = "Drums";
    }else{
        name = program_names[program & 127];
    }
    NSString* localized = NSLocalizedString([NSString stringWithCString:name], nil);
    std::sprintf(s, "ch%d-program", ch + 1);
    [view setText:[localized lossyCString] forKey:s];
}

static void update_spectrum(void)
{
    double spectrum[16];
    if(no_spectrum){
        for(int i = 0; i < 16; ++i){
            spectrum[i] = 0;
        }
    }else{
        std::complex<double> time[512];
        std::complex<double> freq[512];
        for(int i = 0; i < 512; ++i){
            time[i] = (last_512samples[i * 2] + last_512samples[i * 2 + 1]) / 32768.0;
        }
        float rate = sampling_rate;
        filter::fft(freq, time, 9);
        static const int freqmap[16] = {
            50, 100, 200, 300, 400, 600, 800, 1000,
            1200, 1600, 2400, 3200, 4800, 6400, 9600, INT_MAX
        };
        for(int i = 0; i < 16; ++i){
            spectrum[i] = 0;
        }
        for(int i = 0; i < 256; ++i){
            float f = rate * i / 512;
            for(int j = 0; j < 16; ++j){
                if(f < freqmap[j]){
                    spectrum[j] = std::max(spectrum[j], std::abs(freq[i]));
                    break;
                }
            }
        }
        if(note_count == 0){
            no_spectrum = true;
        }
        for(int i = 0; i < 16; ++i){
            spectrum[i] = std::min(1.0, std::log10(spectrum[i] + 1) / 2);
            if(spectrum[i] > 0.01){
                no_spectrum = false;
            }
        }
    }
    for(int i = 0; i < 16; ++i){
        char s[64];
        std::sprintf(s, "spectrum%d", i + 1);
        [view setValue:spectrum[i] forKey:s type:UI_VERTICAL];
    }
}

static void update_all_parameters(void)
{
    char s[64];
    int i, j;
    [view setText:sequencer.get_title().c_str() forKey:"title"];
    [view setText:sequencer.get_copyright().c_str() forKey:"copyright"];
    [view setText:"" forKey:"song"];
    [view setValue:sequencer_time / sequencer.get_total_time() forKey:"position" type:UI_HORIZONTAL];
    std::sprintf(s, "%d", bpm);
    [view setText:s forKey:"bpm"];
    std::sprintf(s, "%d", note_count);
    [view setText:s forKey:"notecount"];
    update_spectrum();
    [view setValue:synthesizer.get_master_volume() / 16384.0 forKey:"port1-mastervolume" type:UI_HORIZONTAL];
    [view setValue:synthesizer.get_master_balance() / 16384.0 forKey:"port1-masterbalance" type:UI_HORIZONTAL_CENTER];
    [view setValue:synthesizer.get_master_fine_tuning() / 16384.0 forKey:"port1-masterfinetuning" type:UI_HORIZONTAL_CENTER];
    [view setValue:synthesizer.get_master_coarse_tuning() / 16384.0 forKey:"port1-mastercoarsetuning" type:UI_HORIZONTAL_CENTER];
    [view setValue:synthesizer.get_system_mode() == midisynth::system_mode_gm forKey:"port1-systemmode-gm" type:UI_HORIZONTAL];
    [view setValue:synthesizer.get_system_mode() == midisynth::system_mode_gm2 forKey:"port1-systemmode-gm2" type:UI_HORIZONTAL];
    [view setValue:synthesizer.get_system_mode() == midisynth::system_mode_gs forKey:"port1-systemmode-gs" type:UI_HORIZONTAL];
    [view setValue:synthesizer.get_system_mode() == midisynth::system_mode_xg forKey:"port1-systemmode-xg" type:UI_HORIZONTAL];
    apply_mute();
    for(i = 0; i < 16; ++i){
        update_controls(i);
        update_program(i);
        for(j = 0; j < 128; ++j){
            std::sprintf(s, "ch%d-key%d", i + 1, j);
            [view setValue:0 forKey:s type:UI_HORIZONTAL];
        }
    }
}

static void midi_message(int port, uint_least32_t message)
{
    if(seeking){
        switch(message & 0xF0){
        case 0xB0:
        case 0xC0:
        case 0xD0:
        case 0xE0:
        case 0xF0:
            synthesizer.midi_event(message);
            break;
        }
        return;
    }
    synthesizer.midi_event(message);
    int ch = message & 0x0F;
    int param1 = (message >> 8) & 0x7F;
    int param2 = (message >> 16) & 0x7F;
    switch(message & 0xF0){
    case 0x80:
        update_note(ch, param1, false);
        break;
    case 0x90:
        update_note(ch, param1, param2);
        break;
    case 0xA0:
        break;
    case 0xB0:
        update_controls(ch);
        break;
    case 0xC0:
        update_program(ch);
        break;
    case 0xD0:
        update_controls(ch);
        break;
    case 0xE0:
        update_controls(ch);
        break;
    default:
        update_all_parameters();
        break;
    }
}
static void sysex_message(int port, const void* data, std::size_t size)
{
    synthesizer.sysex_message(data, size);
    if(!seeking){
        update_all_parameters();
    }
}
static void meta_event(int type, const void* data, std::size_t size)
{
    char s[64];
    const unsigned char* p = (const unsigned char*)data;
    if(type == 0x51 && size == 3){
        int tempo = (p[0] << 16) | (p[1] << 8) | p[2];
        bpm = 60000000 / tempo;
        if(!seeking){
            std::sprintf(s, "%d", bpm);
            [view setText:s forKey:"bpm"];
        }
    }
}
static void reset(void)
{
    synthesizer.reset();
    bpm = 120;
    if(!seeking){
        update_all_parameters();
    }
}

static class mymidioutput: public midisequencer::output{
public:
    virtual void midi_message(int port, uint_least32_t message)
    {
        ::midi_message(port, message);
    }
    virtual void sysex_message(int port, const void* data, std::size_t size)
    {
        ::sysex_message(port, data, size);
    }
    virtual void meta_event(int type, const void* data, std::size_t size)
    {
        ::meta_event(type, data, size);
    }
    virtual void reset()
    {
        ::reset();
    }
}mymidioutput;

static void midi_thread(void)
{
    NSDate* last_time = NULL;
    [lock lockWhenCondition:LOCK_CONDITION_INITIALIZING];
    [lock unlockWithCondition:LOCK_CONDITION_READY];
    while(status != STATUS_TERMINATING){
        if(status == STATUS_PLAYING && last_time){
            NSAutoreleasePool* pool = [[NSAutoreleasePool alloc]init];
            [lock lock];
            NSDate* t = [[NSDate alloc] init];
            sequencer_time += [t timeIntervalSinceDate:last_time];
            [last_time release];
            last_time = t;
            sequencer.play(sequencer_time, &mymidioutput);
            if(seeking){
                update_all_parameters();
                seeking = false;
            }
            if(sequencer_time >= sequencer.get_total_time()){
                NSLog(@"runThread: Stopped.");
                if(status == STATUS_PLAYING){
                    status = STATUS_STOPPED;
                }
            }
            [lock unlock];
            [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
            [pool release];
        }else{
            [lock lockWhenCondition:LOCK_CONDITION_STATUSCHANGED];
            [lock unlockWithCondition:LOCK_CONDITION_READY];
            [last_time release];
            last_time = [[NSDate alloc] init];
        }
    }
    [lock lock];
    [lock unlockWithCondition:LOCK_CONDITION_TERMINATED];
}

static void update_thread(void)
{
    double sequencer_time = 0;
    while(status != STATUS_TERMINATING){
        NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
        if(sequencer_time != ::sequencer_time){
            sequencer_time = ::sequencer_time;
            [lock lock];
            [view setValue:sequencer_time / sequencer.get_total_time() forKey:"position" type:UI_HORIZONTAL];
            [lock unlock];
        }
		[view performSelectorOnMainThread:@selector(updateElements) withObject:nil waitUntilDone:NO];
        [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.016]];
        [pool release];
    }
}

static void spectrum_thread(void)
{
    int last_note_count = 0;
    while(status != STATUS_TERMINATING){
        NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
        if(1/*[view canDraw]*/){
            if(last_note_count != note_count){
                char s[64];
                last_note_count = note_count;
                std::sprintf(s, "%d", note_count);
                [view setText:s forKey:"notecount"];
            }
            update_spectrum();
        }
        [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        [pool release];
    }
}

static bool load_programs(const char* filename)
{
    std::FILE* fp = std::fopen(filename, "rt");
    if(fp){
        while(!std::feof(fp)){
            int c = std::getc(fp);
            if(c == '@'){
                int prog;
                midisynth::FMPARAMETER p;
                if(std::fscanf(fp, "%d%d%d%d", &prog, &p.ALG, &p.FB, &p.LFO) == 4
                && std::fscanf(fp, "%d%d%d%d%d%d%d%d%d%d", &p.op1.AR, &p.op1.DR, &p.op1.SR, &p.op1.RR, &p.op1.SL, &p.op1.TL, &p.op1.KS, &p.op1.ML, &p.op1.DT, &p.op1.AMS) == 10
                && std::fscanf(fp, "%d%d%d%d%d%d%d%d%d%d", &p.op2.AR, &p.op2.DR, &p.op2.SR, &p.op2.RR, &p.op2.SL, &p.op2.TL, &p.op2.KS, &p.op2.ML, &p.op2.DT, &p.op2.AMS) == 10
                && std::fscanf(fp, "%d%d%d%d%d%d%d%d%d%d", &p.op3.AR, &p.op3.DR, &p.op3.SR, &p.op3.RR, &p.op3.SL, &p.op3.TL, &p.op3.KS, &p.op3.ML, &p.op3.DT, &p.op3.AMS) == 10
                && std::fscanf(fp, "%d%d%d%d%d%d%d%d%d%d", &p.op4.AR, &p.op4.DR, &p.op4.SR, &p.op4.RR, &p.op4.SL, &p.op4.TL, &p.op4.KS, &p.op4.ML, &p.op4.DT, &p.op4.AMS) == 10){
                    note_factory.set_program(prog, p);
                }
            }else if(c == '*'){
                int prog;
                midisynth::DRUMPARAMETER p;
                if(std::fscanf(fp, "%d%d%d%d%d%d%d", &prog, &p.ALG, &p.FB, &p.LFO, &p.key, &p.panpot, &p.assign) == 7
                && std::fscanf(fp, "%d%d%d%d%d%d%d%d%d%d", &p.op1.AR, &p.op1.DR, &p.op1.SR, &p.op1.RR, &p.op1.SL, &p.op1.TL, &p.op1.KS, &p.op1.ML, &p.op1.DT, &p.op1.AMS) == 10
                && std::fscanf(fp, "%d%d%d%d%d%d%d%d%d%d", &p.op2.AR, &p.op2.DR, &p.op2.SR, &p.op2.RR, &p.op2.SL, &p.op2.TL, &p.op2.KS, &p.op2.ML, &p.op2.DT, &p.op2.AMS) == 10
                && std::fscanf(fp, "%d%d%d%d%d%d%d%d%d%d", &p.op3.AR, &p.op3.DR, &p.op3.SR, &p.op3.RR, &p.op3.SL, &p.op3.TL, &p.op3.KS, &p.op3.ML, &p.op3.DT, &p.op3.AMS) == 10
                && std::fscanf(fp, "%d%d%d%d%d%d%d%d%d%d", &p.op4.AR, &p.op4.DR, &p.op4.SR, &p.op4.RR, &p.op4.SL, &p.op4.TL, &p.op4.KS, &p.op4.ML, &p.op4.DT, &p.op4.AMS) == 10){
                    note_factory.set_drum_program(prog, p);
                }
            }
        }
        std::fclose(fp);
        return true;
    }
    return false;
}

static std::map<std::string, void(*)(float, const char*, bool)> mouse_down_handlers;
static std::map<std::string, void(*)(float, const char*)> mouse_drag_handlers;
static std::map<std::string, void(*)(float, const char*)> mouse_up_handlers;

static void mouse_handler_position(float value, const char*)
{
    [lock lock];
    seeking = true;
    sequencer_time = sequencer.get_total_time() * value;
    synthesizer.all_sound_off();
    [lock unlock];
}
static void mouse_handler_master_volume(float value, const char*)
{
    synthesizer.set_master_volume((int)(value * 16383));
    update_all_parameters();
}
static void mouse_handler_master_balance(float value, const char*)
{
    synthesizer.set_master_balance((int)(value * 16383));
    update_all_parameters();
}
static void mouse_handler_master_fine_tuning(float value, const char*)
{
    synthesizer.set_master_fine_tuning((int)(value * 16383));
    update_all_parameters();
}
static void mouse_handler_master_coarse_tuning(float value, const char*)
{
    synthesizer.set_master_coarse_tuning((int)(value * 16383));
    update_all_parameters();
}
static void mouse_handler_reset_gm(float, const char*, bool)
{
    synthesizer.set_system_mode(midisynth::system_mode_gm);
    update_all_parameters();
}
static void mouse_handler_reset_gm2(float, const char*, bool)
{
    synthesizer.set_system_mode(midisynth::system_mode_gm2);
    update_all_parameters();
}
static void mouse_handler_reset_gs(float, const char*, bool)
{
    synthesizer.set_system_mode(midisynth::system_mode_gs);
    update_all_parameters();
}
static void mouse_handler_reset_xg(float, const char*, bool)
{
    synthesizer.set_system_mode(midisynth::system_mode_xg);
    update_all_parameters();
}
static int parse_channel(const char* s)
{
    int ch;
    if(std::sscanf(s, "ch%d-", &ch) == 1){
        return ch - 1;
    }else{
        return 0;
    }
}
static void mouse_handler_mute(float, const char* s, bool)
{
    int ch = parse_channel(s);
    mute[ch] = !mute[ch];
    apply_mute();
}
static void mouse_handler_solo(float, const char* s, bool)
{
    int ch = parse_channel(s);
    if(solo == ch){
        solo = -1;
    }else{
        solo = ch;
    }
    apply_mute();
}
static void mouse_handler_damper(float, const char* s, bool)
{
    int ch = parse_channel(s);
    synthesizer.get_channel(ch)->set_damper(127);
    update_controls(ch);
}
static void mouse_handler_damper_up(float, const char* s)
{
    int ch = parse_channel(s);
    synthesizer.get_channel(ch)->set_damper(0);
    update_controls(ch);
}
static void mouse_handler_sostenute(float, const char* s, bool)
{
    int ch = parse_channel(s);
    synthesizer.get_channel(ch)->set_sostenute(127);
    update_controls(ch);
}
static void mouse_handler_sostenute_up(float, const char* s)
{
    int ch = parse_channel(s);
    synthesizer.get_channel(ch)->set_sostenute(0);
    update_controls(ch);
}
static void mouse_handler_freeze(float, const char* s, bool)
{
    int ch = parse_channel(s);
    synthesizer.get_channel(ch)->set_freeze(127);
    update_controls(ch);
}
static void mouse_handler_freeze_up(float, const char* s)
{
    int ch = parse_channel(s);
    synthesizer.get_channel(ch)->set_freeze(0);
    update_controls(ch);
}
static void mouse_handler_panpot(float value, const char* s)
{
    int ch = parse_channel(s);
    synthesizer.get_channel(ch)->set_panpot((int)(value * 16383));
    update_controls(ch);
}
static void mouse_handler_volume(float value, const char* s)
{
    int ch = parse_channel(s);
    synthesizer.get_channel(ch)->set_volume((int)(value * 16383));
    update_controls(ch);
}
static void mouse_handler_expression(float value, const char* s)
{
    int ch = parse_channel(s);
    synthesizer.get_channel(ch)->set_expression((int)(value * 16383));
    update_controls(ch);
}
static void mouse_handler_pitch_bend(float value, const char* s)
{
    int ch = parse_channel(s);
    synthesizer.get_channel(ch)->pitch_bend_change((int)(value * 16383));
    update_controls(ch);
}
static void mouse_handler_pitch_bend_sensitivity(float value, const char* s)
{
    int ch = parse_channel(s);
    synthesizer.get_channel(ch)->set_pitch_bend_sensitivity((int)(value * 16383));
    update_controls(ch);
}
static void mouse_handler_channel_pressure(float value, const char* s)
{
    int ch = parse_channel(s);
    synthesizer.get_channel(ch)->channel_pressure((int)(value * 127));
    update_controls(ch);
}
static void mouse_handler_modulation_depth(float value, const char* s)
{
    int ch = parse_channel(s);
    synthesizer.get_channel(ch)->set_modulation_depth((int)(value * 16383));
    update_controls(ch);
}
static void mouse_handler_modulation_depth_range(float value, const char* s)
{
    int ch = parse_channel(s);
    synthesizer.get_channel(ch)->set_modulation_depth_range((int)(value * 16383));
    update_controls(ch);
}
static void mouse_handler_fine_tuning(float value, const char* s)
{
    int ch = parse_channel(s);
    synthesizer.get_channel(ch)->set_fine_tuning((int)(value * 16383));
    update_controls(ch);
}
static void mouse_handler_coarse_tuning(float value, const char* s)
{
    int ch = parse_channel(s);
    synthesizer.get_channel(ch)->set_coarse_tuning((int)(value * 16383));
    update_controls(ch);
}
static void mouse_handler_program(float, const char* s, bool alt)
{
    int ch = parse_channel(s);
    int program = synthesizer.get_channel(ch)->get_program();
    if(alt){
        program = (program + 127) & 127;
    }else{
        program = (program + 1) & 127;
    }
    midi_message(0, 0xC0 | ch | (program << 8));
}
static void mouse_handler_key(float, const char* s, bool)
{
    int ch, key;
    if(std::sscanf(s, "ch%d-key%d", &ch, &key) == 2){
        midi_message(0, 0x7F0090 | (ch - 1) | (key << 8));
    }
}
static void mouse_handler_key_up(float, const char* s)
{
    int ch, key;
    if(std::sscanf(s, "ch%d-key%d", &ch, &key) == 2){
        midi_message(0, 0x000090 | (ch - 1) | (key << 8));
    }
}

static void initialize_handlers(void)
{
    int i, j;
    char s[64];
    mouse_drag_handlers["position"] = mouse_handler_position;
    mouse_drag_handlers["port1-mastervolume"] = mouse_handler_master_volume;
    mouse_drag_handlers["port1-masterbalance"] = mouse_handler_master_balance;
    mouse_drag_handlers["port1-masterfinetuning"] = mouse_handler_master_fine_tuning;
    mouse_drag_handlers["port1-mastercoarsetuning"] = mouse_handler_master_coarse_tuning;
    mouse_down_handlers["port1-systemmode-gm"] = mouse_handler_reset_gm;
    mouse_down_handlers["port1-systemmode-gm2"] = mouse_handler_reset_gm2;
    mouse_down_handlers["port1-systemmode-gs"] = mouse_handler_reset_gs;
    mouse_down_handlers["port1-systemmode-xg"] = mouse_handler_reset_xg;
    for(i = 1; i <= 16; ++i){
        std::sprintf(s, "ch%d-mute", i);
        mouse_down_handlers[s] = mouse_handler_mute;
        std::sprintf(s, "ch%d-solo", i);
        mouse_down_handlers[s] = mouse_handler_solo;
        std::sprintf(s, "ch%d-damper", i);
        mouse_down_handlers[s] = mouse_handler_damper;
        mouse_up_handlers[s] = mouse_handler_damper_up;
        std::sprintf(s, "ch%d-sostenute", i);
        mouse_down_handlers[s] = mouse_handler_sostenute;
        mouse_up_handlers[s] = mouse_handler_sostenute_up;
        std::sprintf(s, "ch%d-freeze", i);
        mouse_down_handlers[s] = mouse_handler_freeze;
        mouse_up_handlers[s] = mouse_handler_freeze_up;
        std::sprintf(s, "ch%d-pan", i);
        mouse_drag_handlers[s] = mouse_handler_panpot;
        std::sprintf(s, "ch%d-volume", i);
        mouse_drag_handlers[s] = mouse_handler_volume;
        std::sprintf(s, "ch%d-expression", i);
        mouse_drag_handlers[s] = mouse_handler_expression;
        std::sprintf(s, "ch%d-pitchbend", i);
        mouse_drag_handlers[s] = mouse_handler_pitch_bend;
        std::sprintf(s, "ch%d-pitchbendsensitivity", i);
        mouse_drag_handlers[s] = mouse_handler_pitch_bend_sensitivity;
        std::sprintf(s, "ch%d-channelpressure", i);
        mouse_drag_handlers[s] = mouse_handler_channel_pressure;
        std::sprintf(s, "ch%d-modulationdepth", i);
        mouse_drag_handlers[s] = mouse_handler_modulation_depth;
        std::sprintf(s, "ch%d-modulationdepthrange", i);
        mouse_drag_handlers[s] = mouse_handler_modulation_depth_range;
        std::sprintf(s, "ch%d-finetuning", i);
        mouse_drag_handlers[s] = mouse_handler_fine_tuning;
        std::sprintf(s, "ch%d-coarsetuning", i);
        mouse_drag_handlers[s] = mouse_handler_coarse_tuning;
        std::sprintf(s, "ch%d-program", i);
        mouse_down_handlers[s] = mouse_handler_program;
        for(int j = 0; j < 128; ++j){
            std::sprintf(s, "ch%d-key%d", i, j);
            mouse_down_handlers[s] = mouse_handler_key;
            mouse_up_handlers[s] = mouse_handler_key_up;
        }
    }
}

@implementation MyController

- (id)init
{
    self = [super init];
    if(self){
        lock = [[NSConditionLock alloc] initWithCondition:LOCK_CONDITION_INITIALIZING];
        if(lock){
            return self;
        }
        [self release];
    }
    return nil;
}
- (void)dealloc
{
    [lock lock];
    status = STATUS_TERMINATING;
    [lock unlockWithCondition:LOCK_CONDITION_STATUSCHANGED];
    [lock lockWhenCondition:LOCK_CONDITION_TERMINATED beforeDate:[NSDate dateWithTimeIntervalSinceNow:5]];
    [lock unlock];
    finalize_audio();
    [lock release];
    [super dealloc];
}

- (void)runMidiThread:(id)arg
{
    midi_thread();
}
- (void)runSpectrumThread:(id)arg
{
    [NSThread setThreadPriority:[NSThread threadPriority] - 0.2];
    spectrum_thread();
}
- (void)runUpdateThread:(id)arg
{
    [NSThread setThreadPriority:[NSThread threadPriority] - 0.1];
    update_thread();
}

- (void)applicationWillFinishLaunching:(NSNotification *)aNotification
{
    NSSize size = [myView preferredSize];
    [window setContentSize:size];
    [window makeKeyAndOrderFront:self];
    [window registerForDraggedTypes:[NSArray arrayWithObjects:NSFilenamesPboardType, nil]];
    view = myView;
    initialize_handlers();
    load_programs([[[NSBundle mainBundle] pathForResource:@"programs" ofType:@"txt"] lossyCString]);

    if(!initialize_audio()){
        [self alert:@"Failed to initialize AudioUnit."];
    }else{
        [NSThread detachNewThreadSelector:@selector(runUpdateThread:)
                                 toTarget:self
                               withObject:nil];
        [NSThread detachNewThreadSelector:@selector(runSpectrumThread:)
                                 toTarget:self
                               withObject:nil];
        [NSThread detachNewThreadSelector:@selector(runMidiThread:)
                                 toTarget:self
                               withObject:nil];
        [lock lockWhenCondition:LOCK_CONDITION_READY beforeDate:[NSDate dateWithTimeIntervalSinceNow:10]];
        int condition = [lock condition];
        [lock unlock];
        if(condition != LOCK_CONDITION_READY){
            [self alert:@"Failed to start the MIDI playback thread."];
        }
        update_all_parameters();
    }
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag
{
    [window makeKeyAndOrderFront:self];
    return YES;
}

- (void)alert:(NSString*)message
{
    NSBeginCriticalAlertSheet(@"Alert", @"Continue", nil, nil, window, self, @selector(alertSheetDidEnd:returnCode:contextInfo:), @selector(alertSheetDidDismiss:returnCode:contextInfo:), NULL, message, nil);
}
- (void)alertSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
    /* nothing to do. */
}
- (void)alertSheetDidDismiss:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
    /* nothing to do. */
}

- (void)openDocument:(id)sender
{
    NSOpenPanel* openPanel = [NSOpenPanel openPanel];
    [openPanel beginSheetForDirectory:NSHomeDirectory()
                                 file:nil
                                types:[NSArray arrayWithObjects:@"mid", @"smf", nil]
                       modalForWindow:window
                        modalDelegate:self
                       didEndSelector:@selector(openPanelDidEnd:returnCode:contextInfo:)
                          contextInfo:NULL];
}
- (void)openPanelDidEnd:(NSOpenPanel *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
    if(returnCode == NSOKButton){
        NSDocument* document = [self openDocumentWithContentsOfFile:[sheet filename]
                                                            display:NO];
        if(!document){
            [self alert:@"Failed to open the document."];
        }
    }
}
- (id)openDocumentWithContentsOfFile:(NSString *)fileName display:(BOOL)flag
{
    NSDocument* document = [super openDocumentWithContentsOfFile:fileName display:flag];
    if(document){
        [[document retain] autorelease];
        [window setTitleWithRepresentedFilename:[document fileName]];
        [self removeDocument:document];
    }
    return document;
}
- (id)openDocumentWithContentsOfURL:(NSURL *)aURL display:(BOOL)flag
{
    NSDocument* document = [super openDocumentWithContentsOfURL:aURL display:flag];
    if(document){
        [[document retain] autorelease];
        [window setTitleWithRepresentedFilename:[document fileName]];
        [self removeDocument:document];
    }
    return document;
}

- (IBAction)orderFrontStandardAboutPanel:(id)sender
{
    [NSApp orderFrontStandardAboutPanelWithOptions:
        [NSDictionary dictionaryWithObject:NSLocalizedString(@"AppTitle", nil)
                                    forKey:@"ApplicationName"]];
}
- (IBAction)applyPreferences:(id)sender
{
    float rate = [matrixSamplingRate selectedTag];
    if(rate != sampling_rate){
        [lock lock];
        sampling_rate = rate;
        [lock unlock];
    }
    int tap = (int)std::floor(std::pow(2, [sliderTap floatValue]) / 2 + 0.5) * 2 - 1;
    [textTap setIntValue:tap];
    std::map<double, double> gains;
    gains[62.5] = std::pow(10, [slider62Hz doubleValue] / 20);
    gains[125] = std::pow(10, [slider125Hz doubleValue] / 20);
    gains[250] = std::pow(10, [slider250Hz doubleValue] / 20);
    gains[500] = std::pow(10, [slider500Hz doubleValue] / 20);
    gains[1000] = std::pow(10, [slider1kHz doubleValue] / 20);
    gains[2000] = std::pow(10, [slider2kHz doubleValue] / 20);
    gains[4000] = std::pow(10, [slider4kHz doubleValue] / 20);
    gains[8000] = std::pow(10, [slider8kHz doubleValue] / 20);
    gains[16000] = std::pow(10, [slider16kHz doubleValue] / 20);
    bool equalizer_updated = false;
    bool equalizer_enabled = false;
    for(std::map<double, double>::iterator i = gains.begin(); i != gains.end(); ++i){
        if(equalizer_gains[i->first] != i->second){
            equalizer_updated = true;
        }
        if(i->second != 1){
            equalizer_enabled = true;
        }
    }
    if(equalizer_updated){
        std::vector<double> h(tap + 1);
        filter::compute_equalizer_fir(&h[0], h.size(), sampling_rate, gains);
        equalizer_gains = gains;
        [lock lock];
        ::equalizer_enabled = equalizer_enabled;
        equalizer_left.set_impulse_response(h);
        equalizer_right.set_impulse_response(h);
        [lock unlock];
    }
}
- (IBAction)resetEqualizer:(id)sender
{
    [slider62Hz setDoubleValue:0];
    [slider125Hz setDoubleValue:0];
    [slider250Hz setDoubleValue:0];
    [slider500Hz setDoubleValue:0];
    [slider1kHz setDoubleValue:0];
    [slider2kHz setDoubleValue:0];
    [slider4kHz setDoubleValue:0];
    [slider8kHz setDoubleValue:0];
    [slider16kHz setDoubleValue:0];
    equalizer_enabled = false;
}
- (IBAction)resumePlayback:(id)sender
{
    [lock lock];
    status = STATUS_PLAYING;
    [lock unlockWithCondition:LOCK_CONDITION_STATUSCHANGED];
}
- (IBAction)pausePlayback:(id)sender
{
    [lock lock];
    status = STATUS_STOPPED;
    synthesizer.all_note_off();
    [lock unlock];
}
- (IBAction)rewindSequencer:(id)sender
{
    [lock lock];
    seeking = true;
    sequencer_time = 0;
    [lock unlock];
}

- (void)mouseDown:(float)value inElement:(const char*)element withModifiers:(unsigned int)modifiers
{
    void (*p)(float, const char*, bool) = mouse_down_handlers[element];
    if(p){
        bool alt = modifiers & NSAlternateKeyMask;
        p(value, element, alt);
    }
    [self mouseDragged:value inElement:element];
}
- (void)mouseDragged:(float)value inElement:(const char*)element
{
    void (*p)(float, const char*) = mouse_drag_handlers[element];
    if(p){
        p(value, element);
    }
}
- (void)mouseUp:(float)value inElement:(const char*)element
{
    void (*p)(float, const char*) = mouse_up_handlers[element];
    if(p){
        p(value, element);
    }
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
    return NSDragOperationGeneric & [sender draggingSourceOperationMask];
}
- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender
{
    return NSDragOperationGeneric & [sender draggingSourceOperationMask];
}
- (void)draggingExited:(id <NSDraggingInfo>)sender
{
}
- (BOOL)prepareForDragOperation:(id <NSDraggingInfo>)sender
{
    return YES;
}
- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
    NSPasteboard* pboard = [sender draggingPasteboard];
    NSArray* types = [pboard types];
    if([types containsObject:NSFilenamesPboardType]){
        NSArray* files = [pboard propertyListForType:NSFilenamesPboardType];
        if(files && [files count] == 1){
            NSString* filename = [files objectAtIndex:0];
            if([self openDocumentWithContentsOfFile:filename display:NO]){
                return YES;
            }
        }
    }
    return NO;
}
- (void)concludeDragOperation:(id <NSDraggingInfo>)sender
{
}
- (void)draggingEnded:(id <NSDraggingInfo>)sender
{
}

@end

struct myreadfunc_t{
    const unsigned char* data;
    const unsigned char* last;
};

static int myreadfunc(void* fp)
{
    struct myreadfunc_t* p = (struct myreadfunc_t*)fp;
    if(p->data == p->last){
        return EOF;
    }
    return *p->data++;
}

@interface MyDocument : NSDocument
@end
@implementation MyDocument
- (BOOL)loadDataRepresentation:(NSData *)docData ofType:(NSString *)docType
{
    BOOL ret;
    struct myreadfunc_t t;
    t.data = (const unsigned char*)[docData bytes];
    t.last = t.data + [docData length];
    [[view window] setTitle:NSLocalizedString(@"Untitled", nil)];
    [lock lock];
    sequencer_time = 0;
    status = STATUS_STOPPED;
    ret = NO;
    try{
        if(sequencer.load(&t, myreadfunc)){
            status = STATUS_PLAYING;
            ret = YES;
        }
    }catch(...){
    }
    reset();
    [lock unlockWithCondition:LOCK_CONDITION_STATUSCHANGED];
    return ret;
}
- (BOOL)loadFileWrapperRepresentation:(NSFileWrapper *)wrapper ofType:(NSString *)docType
{
    while([wrapper isSymbolicLink]){
        wrapper = [[[NSFileWrapper alloc] initWithPath:[wrapper symbolicLinkDestination]] autorelease];
    }
    if([wrapper isRegularFile]){
        return [self loadDataRepresentation:[wrapper regularFileContents] ofType:docType];
    }else{
        return NO;
    }
}
@end
