// libShimApplicationServices.dylib — Speech Synthesis Manager stubs for
// SDLDrv (in-game text-to-speech). Channel creation fails, so the game skips
// speech instead of calling into a framework iOS does not have.
#include <stdint.h>

#define EXPORT __attribute__((visibility("default")))

EXPORT int16_t NewSpeechChannel(void *voice, void **chan)
{
    (void)voice;
    if (chan)
        *chan = 0;
    return -1;
}

EXPORT int16_t DisposeSpeechChannel(void *chan)
{
    (void)chan;
    return 0;
}

EXPORT int16_t SpeakText(void *chan, const void *text, unsigned long len)
{
    (void)chan;
    (void)text;
    (void)len;
    return -1;
}

EXPORT uint8_t SpeechBusy(void)
{
    return 0;
}

EXPORT int16_t StopSpeech(void *chan)
{
    (void)chan;
    return 0;
}
