#ifndef STORYTELLER_SDL_HELPER__
#define STORYTELLER_SDL_HELPER__

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

#include "SDL2/SDL.h"
#include "SDL2/SDL_mixer.h"
#include "SDL2/SDL_image.h"
#include "SDL2/SDL_ttf.h"
#include "SDL2/SDL_gfx.h"

#include "system/display.h"
#include "system/telmi_rev.h"
#include "utils/str.h"

#include "./logs_helper.h"
#include "./app_battery.h"
#include "./app_lock.h"
#include "./app_parameters.h"
#include "./app_volume.h"
#include "./app_brightness.h"

#define SYSTEM_RESOURCES "/mnt/SDCARD/.tmp_update/res/"

#define FALLBACK_FONT_REGULAR "/mnt/SDCARD/.tmp_update/res/Exo2-Regular.ttf"
#define FALLBACK_FONT_BOLD "/mnt/SDCARD/.tmp_update/res/Exo2-Bold.ttf"

#define SDL_ALIGN_LEFT 0
#define SDL_ALIGN_RIGHT 1
#define SDL_ALIGN_CENTER 2

static SDL_Window *window = NULL;
static SDL_Surface *screen = NULL;
static SDL_Surface *appSurface = NULL;
static SDL_Texture *texture = NULL;
static SDL_Renderer *renderer = NULL;
static Mix_Music *music;
static double musicDuration;
static char currentMusicPath[STR_MAX * 2];
/* Si Mix_LoadMUS echoue : evite autoplay qui enchaine toutes les pages */
static Uint32 audioFakeEndMs = 0;
/* Horloge logicielle : Mix_GetMusicPosition/SetMusicPosition + thread duree
 * provoquent freeze/deadlock avec drmp3 sur R36S. */
static double audioClockPosition = 0.0;
static Uint32 audioClockStartMs = 0;
static bool audioClockActive = false;
static bool audioClockPaused = false;
/* Seek mixer differe : Mix_SetMusicPosition est lent (MP3) et bloque l'UI.
 * On met a jour l'horloge tout de suite, puis on applique le seek reel apres
 * une fenetre de coalescence (evite le "trop de skips" pendant le lag). */
static double audioPendingSeekPos = -1.0;
static Uint32 audioPendingSeekAtMs = 0;
static const Uint32 AUDIO_SEEK_COALESCE_MS = 120;
static TTF_Font *fontBold24;
static TTF_Font *fontBold20;
static TTF_Font *fontBold18;
static TTF_Font *fontRegular20;
static TTF_Font *fontRegular18;
static TTF_Font *fontRegular16;

static SDL_Color colorWhite = {255, 255, 255};
static SDL_Color colorWhite60 = {189, 186, 193};
static SDL_Color colorPurple = {37, 16, 58};
static SDL_Color colorOrange = {255, 181, 0};
static SDL_Color colorRed = {238, 45, 0};


static SDL_Surface *cacheSurfaces[16] = {NULL, NULL, NULL, NULL,
                                         NULL, NULL, NULL, NULL,
                                         NULL, NULL, NULL, NULL,
                                         NULL, NULL, NULL, NULL};
static char cacheSurfacesKeys[16][STR_MAX * 2 + 12] = {{'\0'},{'\0'},{'\0'},{'\0'},
                                                       {'\0'},{'\0'},{'\0'},{'\0'},
                                                       {'\0'},{'\0'},{'\0'},{'\0'},
                                                       {'\0'},{'\0'},{'\0'},{'\0'}};

SDL_Surface *video_findCacheSurface(char* surfaceKey) {
    for (int i = 0; i < 16; ++i) {
        if (strcmp(surfaceKey, cacheSurfacesKeys[i]) != 0) {
            continue;
        }

        SDL_Surface *tmpSurface = cacheSurfaces[i];
        for (int j = i; j > 0; --j) {
            strcpy(cacheSurfacesKeys[j], cacheSurfacesKeys[j - 1]);
            cacheSurfaces[j] = cacheSurfaces[j - 1];
        }
        strcpy(cacheSurfacesKeys[0], surfaceKey);
        cacheSurfaces[0] = tmpSurface;
        return tmpSurface;
    }
    return NULL;
}

void video_saveCacheSurface(char *surfaceKey, SDL_Surface *surface) {
    if (cacheSurfaces[15] != NULL) {
        SDL_FreeSurface(cacheSurfaces[15]);
    }
    for (int i = 15; i > 0; --i) {
        strcpy(cacheSurfacesKeys[i], cacheSurfacesKeys[i - 1]);
        cacheSurfaces[i] = cacheSurfaces[i - 1];
    }
    strcpy(cacheSurfacesKeys[0], surfaceKey);
    cacheSurfaces[0] = surface;
}

SDL_Surface *video_loadAndCacheImage(char *imagePath) {
    SDL_Surface *image = video_findCacheSurface(imagePath);
    if (image == NULL) {
        image = IMG_Load(imagePath);
        if (image != NULL) {
            video_saveCacheSurface(imagePath, image);
        }
    }
    return image;
}

void video_screenBlack(void) {
    SDL_FillRect(appSurface, NULL, 0);
}

void video_drawRectangle(int x, int y, int width, int height, Uint8 r, Uint8 g, Uint8 b) {
    SDL_FillRect(appSurface, &(SDL_Rect) {x, y, width, height}, SDL_MapRGB(appSurface->format, r, g, b));
}

void video_screenAddImage(const char *dir, char *name, int x, int y, int width) {
    char imagePath[STR_MAX * 2];
    char imageKey[STR_MAX * 2 + 12];
    sprintf(imagePath, "%s%s", dir, name);
    sprintf(imageKey, "%s|%i", imagePath, width);

    SDL_Surface *image = video_findCacheSurface(imageKey);

    if (image != NULL) {
        SDL_BlitSurface(image, NULL, appSurface, &(SDL_Rect) {x, y});
        return;
    }

    image = IMG_Load(imagePath);

    if (image == NULL) {
        return;
    }

    if (width != image->w) {
        SDL_Surface *imageScaled = rotozoomSurface(image, 0.0, (double) width / (double) image->w, 1);
        if (imageScaled != NULL) {
            SDL_BlitSurface(imageScaled, NULL, appSurface, &(SDL_Rect) {x, y});
            video_saveCacheSurface(imageKey, imageScaled);
        }
        SDL_FreeSurface(image);
    } else {
        SDL_BlitSurface(image, NULL, appSurface, &(SDL_Rect) {x, y});
        video_saveCacheSurface(imageKey, image);
    }
}

/* Fit image dans maxW x maxH (ratio preserve, centre) — pour tuiles 171x128 */
void video_screenAddImageFit(const char *dir, char *name, int x, int y, int maxW, int maxH) {
    char imagePath[STR_MAX * 2];
    char imageKey[STR_MAX * 2 + 24];
    SDL_Surface *image;
    SDL_Surface *scaled;
    double zoom;
    int dx, dy;

    sprintf(imagePath, "%s%s", dir, name);
    sprintf(imageKey, "%s|fit%ix%i", imagePath, maxW, maxH);

    image = video_findCacheSurface(imageKey);
    if (image != NULL) {
        dx = x + (maxW - image->w) / 2;
        dy = y + (maxH - image->h) / 2;
        SDL_BlitSurface(image, NULL, appSurface, &(SDL_Rect) {dx, dy});
        return;
    }

    image = IMG_Load(imagePath);
    if (image == NULL)
        return;

    zoom = (double)maxW / (double)image->w;
    if ((double)image->h * zoom > (double)maxH)
        zoom = (double)maxH / (double)image->h;

    if (zoom != 1.0) {
        scaled = rotozoomSurface(image, 0.0, zoom, 1);
        SDL_FreeSurface(image);
        image = scaled;
    }
    if (image == NULL)
        return;

    dx = x + (maxW - image->w) / 2;
    dy = y + (maxH - image->h) / 2;
    SDL_BlitSurface(image, NULL, appSurface, &(SDL_Rect) {dx, dy});
    video_saveCacheSurface(imageKey, image);
}

void video_screenWriteFont(const char *text, TTF_Font *font, SDL_Color color, int x, int y, int align) {
    SDL_Surface *sdlText;
    int ox;

    if (font == NULL || text == NULL || appSurface == NULL)
        return;

    sdlText = TTF_RenderUTF8_Blended(font, text, color);
    if (sdlText == NULL)
        return;

    /* SDL_ALIGN_LEFT==0 : ne JAMAIS diviser par align (SIGTRAP sur ARM) */
    ox = x;
    if (align == SDL_ALIGN_CENTER)
        ox = x - sdlText->w / 2;
    else if (align == SDL_ALIGN_RIGHT)
        ox = x - sdlText->w;

    SDL_BlitSurface(sdlText, NULL, appSurface, &(SDL_Rect) {ox, y});
    SDL_FreeSurface(sdlText);
}

void video_showBattery(void) {
    int batteryPercentage = app_battery_getPercentage();
    SDL_Color colorBattery;
    if (batteryPercentage < 6) {
        colorBattery = colorRed;
        video_screenAddImage(SYSTEM_RESOURCES, "storytellerBatteryEmpty.png", 531, 2, 76);
    } else if (batteryPercentage < 20) {
        colorBattery = colorOrange;
        video_screenAddImage(SYSTEM_RESOURCES, "storytellerBatteryLow.png", 531, 2, 76);
    } else if (batteryPercentage < 60) {
        colorBattery = colorWhite60;
        video_screenAddImage(SYSTEM_RESOURCES, "storytellerBatteryMedium.png", 531, 2, 76);
    } else {
        colorBattery = colorWhite60;
        video_screenAddImage(SYSTEM_RESOURCES, "storytellerBatteryFull.png", 531, 2, 76);
    }

    char strBatteryPercent[6];
    sprintf(strBatteryPercent, "%i%%", batteryPercentage);
    video_screenWriteFont(strBatteryPercent, fontRegular16, colorBattery, 555, 2, SDL_ALIGN_CENTER);
}

void video_showBar(void) {
    int height, heightMax;
    char imageName[32];
    if(app_brightness_isShowed()) {
        height = app_brightness_getCurrent() * 350 / parameters_getSystemScreenBrightnessMax();
        heightMax = parameters_getScreenBrightnessMax() * 350 / parameters_getSystemScreenBrightnessMax();
        sprintf(imageName, "%s", "storytellerBrightnessBar.png");
    } else if (app_volume_isShowed()) {
        height = app_volume_getCurrent() * 350 / parameters_getSystemAudioVolumeMax();
        heightMax = parameters_getAudioVolumeMax() * 350 / parameters_getSystemAudioVolumeMax();
        sprintf(imageName, "%s", "storytellerVolumeBar.png");
    } else {
        return;
    }

    SDL_FillRect(screen, &(SDL_Rect) {19, 47, 26, 350}, SDL_MapRGB(screen->format, 0, 0, 0));
    SDL_FillRect(screen, &(SDL_Rect) {19, 397 - height, 26, height}, SDL_MapRGB(screen->format, 255, 186, 0));
    if(heightMax < 350) {
        SDL_FillRect(screen, &(SDL_Rect) {19, 397 - heightMax, 26, 2}, SDL_MapRGB(screen->format, 238, 45, 0));
    }

    char imagePath[STR_MAX * 2];
    sprintf(imagePath, "%s%s", SYSTEM_RESOURCES, imageName);
    SDL_Surface *image = video_loadAndCacheImage(imagePath);
    if (image != NULL)
        SDL_BlitSurface(image, NULL, screen, NULL);
}

void video_showAppLock(void) {
    if (!applock_isLocked() && !applock_isRecentlyUnlocked()) {
        return;
    }
    char imagePath[STR_MAX * 2];
    sprintf(imagePath, "%s%s", SYSTEM_RESOURCES, applock_isLocked() ? "storytellerLock.png" : "storytellerUnlock.png");
    SDL_Surface *image = video_loadAndCacheImage(imagePath);
    SDL_BlitSurface(image, NULL, screen, NULL);
}

void video_applyToVideo(void) {
    if (renderer == NULL || texture == NULL || screen == NULL || appSurface == NULL)
        return;
    video_showBattery();
    SDL_BlitSurface(appSurface, NULL, screen, NULL);
    video_showAppLock();
    video_showBar();

    SDL_RenderClear(renderer);
    if (texture != NULL && screen != NULL) {
        SDL_Surface *rgb565 = SDL_ConvertSurfaceFormat(screen, SDL_PIXELFORMAT_RGB565, 0);
        if (rgb565 != NULL) {
            SDL_UpdateTexture(texture, NULL, rgb565->pixels, rgb565->pitch);
            SDL_FreeSurface(rgb565);
        }
        SDL_RenderCopy(renderer, texture, NULL, NULL);
    }
    SDL_RenderPresent(renderer);
}

void video_displayImage(const char *dir, char *name) {
    char imagePath[STR_MAX * 2];
    sprintf(imagePath, "%s%s", dir, name);

    SDL_Surface *image = video_loadAndCacheImage(imagePath);

    SDL_FillRect(appSurface, NULL, 0);
    if (image != NULL) {
        SDL_BlitSurface(
                image,
                NULL,
                appSurface,
                &(SDL_Rect) {(appSurface->w - image->w) / 2, (appSurface->h - image->h) / 2}
        );
    }
    video_applyToVideo();
}

void video_displayBlackScreen(void) {
    video_screenBlack();
    video_applyToVideo();
}

static void audio_clock_set(double position, bool paused)
{
    audioClockPosition = position;
    audioClockStartMs = SDL_GetTicks();
    audioClockActive = true;
    audioClockPaused = paused;
}

static void audio_clock_pause(void)
{
    if (!audioClockActive || audioClockPaused)
        return;
    audioClockPosition += (SDL_GetTicks() - audioClockStartMs) / 1000.0;
    audioClockStartMs = SDL_GetTicks();
    audioClockPaused = true;
}

static void audio_clock_resume(void)
{
    if (!audioClockActive)
        return;
    audioClockStartMs = SDL_GetTicks();
    audioClockPaused = false;
}

bool audio_isFinished(void) {
    if (music != NULL)
        return Mix_PlayingMusic() == 0;
    if (audioFakeEndMs != 0)
        return SDL_GetTicks() >= audioFakeEndMs;
    return true;
}

void audio_free_music(void) {
    audioFakeEndMs = 0;
    audioClockActive = false;
    audioClockPaused = false;
    audioClockPosition = 0.0;
    audioClockStartMs = 0;
    musicDuration = 0.0;
    currentMusicPath[0] = '\0';
    audioPendingSeekPos = -1.0;
    audioPendingSeekAtMs = 0;

    if (music != NULL) {
        Mix_HaltMusic();
        Mix_FreeMusic(music);
        music = NULL;
    }
}

/* A appeler chaque frame : applique le seek mixer apres coalescence. */
void audio_flushPendingSeek(void) {
    double pos;

    if (audioPendingSeekPos < 0.0)
        return;
    if ((SDL_GetTicks() - audioPendingSeekAtMs) < AUDIO_SEEK_COALESCE_MS)
        return;
    if (music == NULL || Mix_PlayingMusic() == 0) {
        audioPendingSeekPos = -1.0;
        return;
    }

    pos = audioPendingSeekPos;
    audioPendingSeekPos = -1.0;
    Mix_SetMusicPosition(pos);
}

void audio_setPosition(double position) {
    if (position < 0.0)
        position = 0.0;
    if (musicDuration > 0.0 && position > musicDuration)
        position = musicDuration;

    /* Horloge UI immediate — reponse ressentie sans attendre le mixer */
    audio_clock_set(position, audioClockPaused || (Mix_PausedMusic() == 1));

    if (music == NULL || Mix_PlayingMusic() == 0)
        return;

    /* Differer Mix_SetMusicPosition (lent) ; coalescer les skips rapides */
    audioPendingSeekPos = position;
    audioPendingSeekAtMs = SDL_GetTicks();
}

void audio_pause_music(void) {
    if (music == NULL)
        return;
    /* Appliquer le seek en attente avant pause (sinon position audio fausse) */
    if (audioPendingSeekPos >= 0.0 && Mix_PlayingMusic() == 1) {
        Mix_SetMusicPosition(audioPendingSeekPos);
        audioPendingSeekPos = -1.0;
    }
    if (Mix_PlayingMusic() == 1 && Mix_PausedMusic() != 1) {
        Mix_PauseMusic();
        audio_clock_pause();
    }
}

void audio_resume_music(void) {
    if (music == NULL)
        return;
    Mix_ResumeMusic();
    audio_clock_resume();
}

bool audio_isPaused(void) {
    return audioClockPaused || (music != NULL && Mix_PausedMusic() == 1);
}

bool audio_hasMusic(void) {
    return music != NULL && Mix_PlayingMusic() == 1;
}

double audio_getDuration(void) {
    return (musicDuration > 0.0) ? musicDuration : 0.0;
}

double audio_getPosition(void) {
    if (!audioClockActive)
        return 0.0;
    if (audioClockPaused)
        return audioClockPosition;
    return audioClockPosition + (SDL_GetTicks() - audioClockStartMs) / 1000.0;
}

void audio_play_path(char *soundPath, double position) {
    audio_free_music();
    music = Mix_LoadMUS(soundPath);
    if (music != NULL) {
        audioFakeEndMs = 0;
        strncpy(currentMusicPath, soundPath, sizeof(currentMusicPath) - 1);
        currentMusicPath[sizeof(currentMusicPath) - 1] = '\0';

        /* Duree sur le handle deja charge — JAMAIS de 2e Mix_LoadMUS en thread */
        {
            double d = Mix_MusicDuration(music);
            musicDuration = (d > 0.0) ? d : 0.0;
        }

        Mix_PlayMusic(music, 1);
        if (position > 0.0)
            Mix_SetMusicPosition(position);
        audio_clock_set(position, false);
        fprintf(stderr, "[storyTeller] play '%s' dur=%.1f pos=%.1f\n",
                soundPath, musicDuration, position);
        fflush(stderr);
    } else {
        fprintf(stderr, "[storyTeller] Mix_LoadMUS FAIL '%s': %s\n", soundPath, Mix_GetError());
        fflush(stderr);
        musicDuration = 5.0;
        currentMusicPath[0] = '\0';
        audioFakeEndMs = SDL_GetTicks() + 5000;
        audio_clock_set(0.0, false);
    }
}

void audio_play(const char *dir, const char *name, double position) {
    char soundPath[STR_MAX * 2];
    sprintf(soundPath, "%s%s", dir, name);
    audio_play_path(soundPath, position);
}

static void st_step(const char *msg) {
    int fd = open("/boot/storyTeller.steps", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0)
        fd = open("/tmp/storyTeller.steps", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        write(fd, msg, strlen(msg));
        write(fd, "\n", 1);
        fsync(fd);
        close(fd);
    }
    write(2, msg, strlen(msg));
    write(2, "\n", 1);
}

void video_audio_init(void) {
    int mixFlags;
    display_getResolution();

    st_step("storyTeller: avant SDL_Init");
    SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO);
    st_step("storyTeller: SDL_Init OK");
    IMG_Init(IMG_INIT_PNG);
    TTF_Init();

    mixFlags = Mix_Init(MIX_INIT_MP3);
    if ((mixFlags & MIX_INIT_MP3) == 0) {
        fprintf(stderr, "[storyTeller] Mix_Init MP3 FAIL: %s (flags=0x%x)\n",
                Mix_GetError(), mixFlags);
        fflush(stderr);
    } else {
        fprintf(stderr, "[storyTeller] Mix_Init MP3 OK (driver=%s)\n",
                SDL_GetCurrentAudioDriver() ? SDL_GetCurrentAudioDriver() : "?");
        fflush(stderr);
    }

    /* Buffer plus grand : hw rk817 + swrast = underruns frequents a 4096 */
    {
        int tries;
        for (tries = 0; tries < 10; tries++) {
            if (Mix_OpenAudio(44100, MIX_DEFAULT_FORMAT, 2, 8192) == 0)
                break;
            fprintf(stderr, "Mix_OpenAudio try %d: %s\n", tries + 1, Mix_GetError());
            fflush(stderr);
            SDL_Delay(500);
        }
        if (tries >= 10)
            fprintf(stderr, "Mix_OpenAudio: ECHEC definitif\n");
        else
            fprintf(stderr, "Mix_OpenAudio OK (try %d)\n", tries + 1);
        fflush(stderr);
    }
    Mix_AllocateChannels(16);
    Mix_Volume(-1, MIX_MAX_VOLUME);
    Mix_VolumeMusic(MIX_MAX_VOLUME);
    /* Playback Path selon /boot/TELMI-REV.txt (image unique multi-REV). */
    {
        char cmd[128];
        snprintf(cmd, sizeof(cmd),
                 "amixer -c 0 cset name='Playback Path' %s 2>/dev/null || true",
                 telmi_audio_path());
        system(cmd);
    }
    system("amixer -c 0 sset Playback 100% unmute 2>/dev/null || true");
    system("amixer -c 0 sset DAC 100% unmute 2>/dev/null || true");
    system("amixer -c 0 sset Headphone unmute 2>/dev/null || true");
    system("amixer -c 0 sset Speaker unmute 2>/dev/null || true");

    fprintf(stderr, "[storyTeller] video_audio_init...\n");
    fflush(stderr);
    st_step("storyTeller: CreateWindow");
    window = SDL_CreateWindow("main", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
        DISPLAY_WIDTH, DISPLAY_HEIGHT, SDL_WINDOW_FULLSCREEN_DESKTOP);
    st_step(window ? "storyTeller: CreateWindow OK" : "storyTeller: CreateWindow FAIL");
    renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
    if (renderer == NULL)
        renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
    st_step(renderer ? "storyTeller: Renderer OK" : "storyTeller: Renderer FAIL");
    screen = SDL_CreateRGBSurface(0, DISPLAY_WIDTH, DISPLAY_HEIGHT, 32, 0, 0, 0, 0);
    appSurface = SDL_CreateRGBSurface(0, DISPLAY_WIDTH, DISPLAY_HEIGHT, 32, 0, 0, 0, 0);
    if (renderer != NULL && screen != NULL)
        texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGB565,
            SDL_TEXTUREACCESS_STREAMING, DISPLAY_WIDTH, DISPLAY_HEIGHT);

    fontBold24 = TTF_OpenFont(FALLBACK_FONT_BOLD, 24);
    fontBold20 = TTF_OpenFont(FALLBACK_FONT_BOLD, 20);
    fontBold18 = TTF_OpenFont(FALLBACK_FONT_BOLD, 18);
    fontRegular20 = TTF_OpenFont(FALLBACK_FONT_REGULAR, 20);
    fontRegular18 = TTF_OpenFont(FALLBACK_FONT_REGULAR, 18);
    fontRegular16 = TTF_OpenFont(FALLBACK_FONT_REGULAR, 16);
    if (fontBold24 == NULL)
        fontBold24 = fontBold20;
    if (fontRegular16 == NULL)
        fontRegular16 = fontRegular18;
}


void video_audio_quit(void) {
    TTF_Quit();

    if (music != NULL) {
        Mix_HaltMusic();
        Mix_FreeMusic(music);
        music = NULL;
    }
    Mix_CloseAudio();

    SDL_FreeSurface(appSurface);
    SDL_FreeSurface(screen);
    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
}

#endif // STORYTELLER_SDL_HELPER__