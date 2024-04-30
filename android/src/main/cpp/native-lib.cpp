#include <jni.h>
#include <string>
#include <fluidsynth.h>
#include <unistd.h>
#include <android/log.h>

#define TAG "recorder"

#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR,    TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,     TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,     TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG,    TAG, __VA_ARGS__)

static fluid_settings_t *settings = NULL;
static fluid_synth_t * synth = NULL;
static fluid_audio_driver_t * adriver = NULL;
static double sampleRate = 44100.0f;
static int32_t framesPerBurst = 192;
static int32_t audioPeriods = 2;
static int32_t audioPeriodSize = 64;
static bool alreadyInitialized = false;
static char sfPath[1024];
static int lastInstrumentIdx = 0;

static fluid_player_t * player = NULL;
static fluid_synth_t * playerSynth = NULL;
static fluid_audio_driver_t * playerADriver = NULL;
static fluid_settings_t *playerSettings = NULL;
static int ticksPerBeat = 960;

jint JNI_OnLoad(JavaVM* vm, void* reserved)
{
    __android_log_print(ANDROID_LOG_INFO, TAG, "JNI_OnLoad");

    return JNI_VERSION_1_6;
}


extern "C" JNIEXPORT bool JNICALL Java_com_artinoise_recorder_FluidSynthDriver_init(JNIEnv* env, jobject) {
    int res;
    __android_log_print(ANDROID_LOG_INFO, TAG, "fluid_synth init");

    if(alreadyInitialized){
            __android_log_print(ANDROID_LOG_INFO, TAG, "ALREADY INITIALIZED! re-initializing...");
                delete_fluid_audio_driver(adriver);
                delete_fluid_synth(synth);
                delete_fluid_settings(settings);

                adriver=NULL;
                synth=NULL;
                settings= NULL;

    }

    // Setup synthesizer
    if( settings == NULL){
        settings = new_fluid_settings();

        res = fluid_settings_setint(settings, "audio.period-size", audioPeriodSize); //192 - framesPerBurst
        __android_log_print(ANDROID_LOG_INFO, TAG, "set  audio.period-size res=%d",res);
        int val = -1;
        res = fluid_settings_getint(settings, "audio.period-size", &val);
        __android_log_print(ANDROID_LOG_INFO, TAG, "now  audio.period-size =%d",val);

        __android_log_print(ANDROID_LOG_INFO, TAG, "setting  audio.period=%d",audioPeriods);
        res = fluid_settings_setint(settings, "audio.periods", audioPeriods);
        __android_log_print(ANDROID_LOG_INFO, TAG, "set  audio.periods res=%d",res);
        val = -1;
        res = fluid_settings_getint(settings, "audio.periods", &val); //192
        __android_log_print(ANDROID_LOG_INFO, TAG, "now  audio.periods =%d",val);

//        res = fluid_settings_setint(settings, "audio.realtime-prio", 99);
//        __android_log_print(ANDROID_LOG_INFO, TAG, "set  realtime-prio res=%d",res);

        res = fluid_settings_setint(settings, "synth.polyphony", 32);
        __android_log_print(ANDROID_LOG_INFO, TAG, "set synth.polyphony res=%d",res);

        res = fluid_settings_setnum(settings, "synth.sample-rate", (double)sampleRate);
        __android_log_print(ANDROID_LOG_INFO, TAG, "set synth.sample-rate res=%d",res);

 //       res = fluid_settings_setint(settings, "synth.cpu-cores", 4);
 //       __android_log_print(ANDROID_LOG_INFO, TAG, "set synth.cpu-cores res=%d",res);

        res = fluid_settings_setint(settings, "synth.chorus.active", 0);
        __android_log_print(ANDROID_LOG_INFO, TAG, "set synth.chorus.active res=%d",res);

        char buf[256];
        res = fluid_settings_copystr(settings, "audio.driver", buf, sizeof(buf));
        __android_log_print(ANDROID_LOG_INFO, TAG, "current audio.driver res=%d val=%s",res,buf);

        res = fluid_settings_setstr (settings, "audio.driver", "oboe");
        __android_log_print(ANDROID_LOG_INFO, TAG, "set audio.driver res=%d",res);
        res = fluid_settings_setint(settings, "audio.opensles.use-callback-mode", 1);
        __android_log_print(ANDROID_LOG_INFO, TAG, "set audio.opensles.use-callback-mode res=%d",res);

        res = fluid_settings_copystr(settings, "audio.driver", buf, sizeof(buf));
        __android_log_print(ANDROID_LOG_INFO, TAG, "new audio.driver res=%d val=%s",res,buf);

        //res = fluid_settings_setstr (settings, "audio.oboe.sharing-mode", "Exclusive");
        //__android_log_print(ANDROID_LOG_INFO, TAG, "set audio.oboe.sharing-mode res=%d",res);

        res = fluid_settings_setstr (settings, "audio.oboe.performance-mode", "LowLatency");
        __android_log_print(ANDROID_LOG_INFO, TAG, "set audio.oboe.performance-mode res=%d",res);

       res = fluid_settings_setnum (settings, "synth.gain", 8.0f);  //0.0 - 10.0 def: 0.2
        __android_log_print(ANDROID_LOG_INFO, TAG, "set synth.gain res=%d",res);


        //reverb
        __android_log_print(ANDROID_LOG_INFO, TAG, "setting reverb.room-size 0.3 level 0.9");
       res = fluid_settings_setnum (settings, "synth.reverb.level", 0.9f);  //0.0 - 1.0 def: 0.9
        __android_log_print(ANDROID_LOG_INFO, TAG, "set reverb.level res=%d",res);
       res = fluid_settings_setnum (settings, "synth.reverb.room-size", 0.3f);  //0.0 - 1.0 def: 0.2
        __android_log_print(ANDROID_LOG_INFO, TAG, "set reverb.room-size res=%d",res);

    }
    if(synth == NULL) {
        LOGI("instancing synth");
        synth = new_fluid_synth(settings);
        LOGI("synth=%p",synth);
    }

    if (adriver == NULL) {
        LOGI("instancing adriver");
        adriver = new_fluid_audio_driver(settings, synth);
        LOGI("adriver=%p",adriver);
    }

    if(alreadyInitialized){
        int ret = fluid_synth_sfload(synth, sfPath, 1);
        __android_log_print(ANDROID_LOG_INFO, TAG, "fluid_synth_sfload path=%s synth=%p adriver=%p ret=%d",sfPath, synth,adriver,ret);
        fluid_synth_program_change(synth, 0, lastInstrumentIdx);
    }

    alreadyInitialized = true;
    return true;
}

extern "C" JNIEXPORT jboolean JNICALL Java_com_artinoise_recorder_FluidSynthDriver_setSF2(JNIEnv* env, jobject, jstring jSoundfontPath) {
    const char* soundfontPath = env->GetStringUTFChars(jSoundfontPath, nullptr);
    snprintf(sfPath,sizeof(sfPath),"%s",soundfontPath);
    // Load sample soundfont
    int ret = fluid_synth_sfload(synth, sfPath, 1);
    __android_log_print(ANDROID_LOG_INFO, TAG, "fluid_synth_sfload path=%s synth=%p adriver=%p sfId=%d (-1=FLUID_FAILED)",soundfontPath, synth,adriver,ret);
    env->ReleaseStringUTFChars(jSoundfontPath, soundfontPath);
    return true;
}

extern "C" JNIEXPORT bool JNICALL Java_com_artinoise_recorder_FluidSynthDriver_write(JNIEnv* env, jobject, jbyteArray array) {
    static const unsigned char MIDI_CMD_NOTE_OFF = 0x80;
    static const unsigned char MIDI_CMD_NOTE_ON = 0x90;
    static const unsigned char MIDI_CMD_NOTE_PRESSURE = 0xa0; //polyphonic key pressure
    static const unsigned char MIDI_CMD_CONTROL = 0xb0; //control change CC
    static const unsigned char MIDI_CMD_PGM_CHANGE = 0xc0;
    static const unsigned char MIDI_CMD_CHANNEL_PRESSURE = 0xd0;
    static const unsigned char MIDI_CMD_BENDER = 0xe0;

    jsize len = env->GetArrayLength(array);
    jbyte *body = env->GetByteArrayElements(array, 0);
    int cmd = body[0];
    int d1 = body[1];
    int d2 = -1;
    if(len>2)
        d2 = body[2];
    int status = cmd & 0xf0;
    int ch = cmd & 0x0f;
    //  __android_log_print(ANDROID_LOG_INFO, APPNAME, "FluidSynthDriver_write received %d bytes cmd=%02x (status=%02x ch=%d) d1=%d d2=%d adriver=%x synth=%x", len, cmd,status,ch,d1,d2,adriver, synth);

    switch (status){
        case MIDI_CMD_NOTE_OFF:
            //__android_log_print(ANDROID_LOG_INFO, TAG, "FluidSynthDriver_sending Note OFF !");
            fluid_synth_noteoff(synth, ch, d1);break;
        case MIDI_CMD_NOTE_ON:
            //__android_log_print(ANDROID_LOG_INFO, TAG, "FluidSynthDriver_sending Note ON !");
            fluid_synth_noteon(synth, ch, d1, d2);break;
            case MIDI_CMD_NOTE_PRESSURE:
            __android_log_print(ANDROID_LOG_INFO, TAG, "FluidSynthDriver_sending Note PRESSURE ! %d %d %d", ch,d1,d2);
            fluid_synth_key_pressure(synth, ch, d1, d2);break;
        case MIDI_CMD_CONTROL:
            //__android_log_print(ANDROID_LOG_INFO, TAG, "FluidSynthDriver_sending Control Change Command! %d %d %d", ch,d1,d2);
            fluid_synth_cc(synth, ch, d1, d2);break;
        case MIDI_CMD_PGM_CHANGE:
            lastInstrumentIdx = d1;
            __android_log_print(ANDROID_LOG_INFO, TAG, "FluidSynthDriver_sending Program Change Command! %d %d", ch,d1);
            fluid_synth_program_change(synth, ch, d1);break;
        case MIDI_CMD_CHANNEL_PRESSURE:
             //__android_log_print(ANDROID_LOG_INFO, TAG, "FluidSynthDriver_sending Channel Pressure Command! %d %d", ch,d1);
           fluid_synth_channel_pressure(synth, ch, d1);break;
        case MIDI_CMD_BENDER:
           //__android_log_print(ANDROID_LOG_INFO, TAG, "FluidSynthDriver_sending Pitch Bend Command! %d %d %d", ch,d1,d2);
           fluid_synth_pitch_bend(synth, ch, ((d2 << 7) | d1));break;
    }
    return true;
}


extern "C" JNIEXPORT void JNICALL Java_com_artinoise_recorder_FluidSynthDriver_shutdown(JNIEnv* env, jobject) {
    __android_log_print(ANDROID_LOG_INFO, TAG, "FluidSynthDriver shutdown");
    // Clean up
    delete_fluid_audio_driver(adriver);
    delete_fluid_synth(synth);
    delete_fluid_settings(settings);
}

extern "C" JNIEXPORT void JNICALL Java_com_artinoise_recorder_FluidSynthDriver_setDefaultStreamValues(JNIEnv *env,
      jclass type,
      jint _sampleRate,
      jint _framesPerBurst) {
    sampleRate = (double) _sampleRate;
    framesPerBurst = (int32_t) _framesPerBurst;
}

extern "C" JNIEXPORT void JNICALL Java_com_artinoise_recorder_FluidSynthDriver_setAudioPeriods(JNIEnv *env,
      jclass type,
      jint _audioPeriods,
      jint _audioPeriodSize){
          audioPeriods = (int32_t) _audioPeriods;
          audioPeriodSize = (int32_t) _audioPeriodSize;
      }

///////////////////////
//FLUID MEDIAPLAYER API
///////////////////////

extern "C" JNIEXPORT jint JNICALL Java_com_artinoise_recorder_FluidSynthDriver_MIDIPrepare(JNIEnv* env, jobject, jstring jfilename, jint _ticksPerBeat) {
    const char* name = env->GetStringUTFChars(jfilename, nullptr);
    // Load file
    if (player){
        delete_fluid_player(player);
    }
    if(playerSettings == NULL){
        playerSettings = new_fluid_settings();
        int res;
        res = fluid_settings_setint(playerSettings, "audio.period-size", audioPeriodSize); //192 - framesPerBurst
        res = fluid_settings_setint(playerSettings, "audio.periods", audioPeriods);
        res = fluid_settings_setnum(playerSettings, "synth.sample-rate", (double)sampleRate);

        res = fluid_settings_setstr(playerSettings, "audio.driver", "oboe");
        res = fluid_settings_setstr(playerSettings, "audio.oboe.performance-mode", "LowLatency");
        res = fluid_settings_setint(playerSettings, "audio.opensles.use-callback-mode", 1);
        res = fluid_settings_setnum(playerSettings, "synth.gain", 1.0f);  //0.0 - 10.0 def: 0.2

        LOGI("playerSettings=%p audio.driver oboe res=%d",playerSettings,res);
    }
    if(playerSynth == NULL) {
        LOGI("instancing playerSynth");
        playerSynth = new_fluid_synth(playerSettings);
        LOGI("playerSynth=%p",playerSynth);
        int ret = fluid_synth_sfload(playerSynth, sfPath, 1);
        __android_log_print(ANDROID_LOG_INFO, TAG, "MIDIPrepare fluid_synth_sfload path=%s synth=%p adriver=%p ret=%d",sfPath, playerSynth,adriver,ret);
    }
    if (playerADriver == NULL) {
        LOGI("instancing playerADriver");
        playerADriver = new_fluid_audio_driver(playerSettings, playerSynth);
        LOGI("playerADriver=%p",playerADriver);
    }


    player = new_fluid_player(playerSynth);
    __android_log_print(ANDROID_LOG_INFO, TAG, "player instance successfully created. player=%p",player);
    if(fluid_is_midifile(name) == true){
        ticksPerBeat = _ticksPerBeat;
        __android_log_print(ANDROID_LOG_INFO, TAG, "%s midi file successfully loaded.",name);
        int res = fluid_player_add(player,name);
        __android_log_print(ANDROID_LOG_INFO, TAG, "fluid_player_add %s res=%d.",name,res);
        env->ReleaseStringUTFChars(jfilename, name);
        fluid_player_stop(player); //why it is starting by itself????
        return res;
    }

    __android_log_print(ANDROID_LOG_INFO, TAG, "error occurred trying to prepare %s",name);
    env->ReleaseStringUTFChars(jfilename, name);
    return FLUID_FAILED;
}

extern "C" JNIEXPORT jint JNICALL Java_com_artinoise_recorder_FluidSynthDriver_MIDIPlay(JNIEnv* env, jobject, jboolean forever) {
    if(player){
        if(forever){
            fluid_player_set_loop(player, -1 /*infinitely*/);
        }
        int res = fluid_player_play(player);
        __android_log_print(ANDROID_LOG_INFO, TAG, "MIDIPlay player = %p res=%d.",player,res);

        return res;
    }
    return FLUID_FAILED;
}

extern "C" JNIEXPORT jint JNICALL Java_com_artinoise_recorder_FluidSynthDriver_MIDIStop(JNIEnv* env, jobject) {
    if(player){
        int res = fluid_player_stop(player);
        int seekres = fluid_player_seek(player,0);
        __android_log_print(ANDROID_LOG_INFO, TAG, "MIDIStop player = %p. stopres=%d seekres=%d",player,res,seekres);
        return res;
    }
    return FLUID_FAILED;
}

extern "C" JNIEXPORT jint JNICALL Java_com_artinoise_recorder_FluidSynthDriver_MIDIPause(JNIEnv* env, jobject) {
    if(player){
        int res =  fluid_player_stop(player);
        __android_log_print(ANDROID_LOG_INFO, TAG, "MIDIPause player = %p. res=%d",player,res);
        return res;
    }
    return FLUID_FAILED;
}

extern "C" JNIEXPORT jint JNICALL Java_com_artinoise_recorder_FluidSynthDriver_MIDIResume(JNIEnv* env, jobject) {
    if(player){
        int res = fluid_player_play(player);
        __android_log_print(ANDROID_LOG_INFO, TAG, "MIDIResume player = %p. res=%d",player,res);
        return res;
    }
    return FLUID_FAILED;
}

extern "C" JNIEXPORT jint JNICALL Java_com_artinoise_recorder_FluidSynthDriver_MIDIGetTotalTicks(JNIEnv* env, jobject) {
    if(player){
        int res = fluid_player_get_total_ticks(player);
        __android_log_print(ANDROID_LOG_INFO, TAG, "MIDIGetTotalTicks player = %p. res=%d",player,res);
        return res;
    }
    return FLUID_FAILED;
}

extern "C" JNIEXPORT jdouble JNICALL Java_com_artinoise_recorder_FluidSynthDriver_MIDIGetCurrentTick(JNIEnv* env, jobject) {
    if(player){
        int tick = fluid_player_get_current_tick(player);
        int bpm = fluid_player_get_bpm(player);
        int status = fluid_player_get_status(player);

        double position = tick / (double)(ticksPerBeat);
        //__android_log_print(ANDROID_LOG_INFO, TAG, "MIDIGetCurrentTick player = %p tick=%d bpm=%d position=%f status=%d.",player,tick,bpm,position,status);
        return position;
    }
    return FLUID_FAILED;
}

extern "C" JNIEXPORT jint JNICALL Java_com_artinoise_recorder_FluidSynthDriver_MIDIGetBpm(JNIEnv* env, jobject) {
    if(player){
        int res = fluid_player_get_bpm(player);
        __android_log_print(ANDROID_LOG_INFO, TAG, "MIDIGetBpm player = %p. res=%d",player, res);
    }
    return FLUID_FAILED;
}

extern "C" JNIEXPORT jint JNICALL Java_com_artinoise_recorder_FluidSynthDriver_MIDIGetTempo(JNIEnv* env, jobject) {
    if(player){
        int res = fluid_player_get_midi_tempo(player);
        __android_log_print(ANDROID_LOG_INFO, TAG, "MIDIGetTempo player = %p. res = %d",player,res);
        return res;
    }
    return FLUID_FAILED;
}

extern "C" JNIEXPORT jint JNICALL Java_com_artinoise_recorder_FluidSynthDriver_MIDIGetStatus(JNIEnv* env, jobject) {
    if(player){
        int res = fluid_player_get_status(player);
        __android_log_print(ANDROID_LOG_INFO, TAG, "MIDIGetStatus player = %p.res=%d",player,res);
        return res;
    }
    return FLUID_FAILED;
}

extern "C" JNIEXPORT jint JNICALL Java_com_artinoise_recorder_FluidSynthDriver_MIDISetVolume(JNIEnv* env, jobject, jdouble v) {
    if(playerSynth){
        int drumCh = 9;
        __android_log_print(ANDROID_LOG_INFO, TAG, "MIDISetVolume player = %p. v=%f",player,v);
        for (int ch = 1; ch<16; ch++){
          if (ch != drumCh){
            int res = fluid_synth_cc(playerSynth, ch, 0x7, (int)v);
            //__android_log_print(ANDROID_LOG_INFO, TAG, "MIDISetVolume player = %p. ch=%d v=%f res=%d",player,ch,v,res);
          }
        }
        return FLUID_OK;
    }

    __android_log_print(ANDROID_LOG_INFO, TAG, "MIDISetVolume ERROR - player = %p playerSynth=%p. v=%d ",player,playerSynth,v);
    return FLUID_FAILED;
}

extern "C" JNIEXPORT jint JNICALL Java_com_artinoise_recorder_FluidSynthDriver_MIDISetTempo(JNIEnv* env, jobject, jdouble v) {
    if(player){
        int res = fluid_player_set_tempo(player,FLUID_PLAYER_TEMPO_INTERNAL,v/100);
        __android_log_print(ANDROID_LOG_INFO, TAG, "MIDISetTempo player = %p. t=%f res=%d",player,v,res);
        return res;
    }
    return FLUID_FAILED;
}

extern "C" JNIEXPORT jint JNICALL Java_com_artinoise_recorder_FluidSynthDriver_MIDISetMetronomeVolume(JNIEnv* env, jobject, jdouble v) {
    if(playerSynth){
        int drumCh = 9;
        int res = fluid_synth_cc(playerSynth, drumCh, 0x7, (int)v);
        __android_log_print(ANDROID_LOG_INFO, TAG, "MIDISetMetronomeVolume player = %p. v=%f ch=%d res=%d",player,v,drumCh,res);
    }
    return FLUID_FAILED;
}



