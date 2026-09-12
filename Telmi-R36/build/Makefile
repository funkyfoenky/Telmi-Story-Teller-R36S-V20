# Build des binaires Telmi pour R36S (aarch64)
# Usage :
#   make -C Telmi-R36/build TELMI_PROFILE=v20
#   make -C Telmi-R36/build TELMI_PROFILE=v30 storyTeller
#   bash Telmi-R36/scripts/build-telmi-bins.sh v30
#
# Staging separe par profil (pas d ecrasement croise) :
#   staging/v20/opt/telmi/bin
#   staging/v30/opt/telmi/bin
# + miroir staging/opt/telmi/bin = dernier profil build (compat Buildroot)

TELMI_R36_DIR := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST)))/..)
# Surchargeable (Buildroot passe le chemin absolu hors du package local)
TELMI_SRC ?= $(TELMI_R36_DIR)/Telmi-story-teller-1.10.1
PLATFORM_DIR := $(TELMI_R36_DIR)/platform/r36s

include $(PLATFORM_DIR)/config.mk

STAGING := $(TELMI_R36_DIR)/staging/$(TELMI_PROFILE)/opt/telmi/bin
STAGING_LEGACY := $(TELMI_R36_DIR)/staging/opt/telmi/bin
STAGING_VER := $(TELMI_R36_DIR)/staging/$(TELMI_PROFILE)/opt/telmi/telmiVersion
ASSETS := $(TELMI_R36_DIR)/assets

# PLATFORM_DIR avant Telmi common : "system/display.h" doit etre le stub R36S,
# pas le display Miyoo (PWM 1f003400) tire via settings.h.
CFLAGS += -I$(PLATFORM_DIR)/storyTeller -I$(PLATFORM_DIR) \
	-I$(TELMI_SRC)/include -I$(TELMI_SRC)/src/common \
	-I$(TELMI_SRC)/src/common/utils \
	$(EXTRA_CFLAGS)
LDFLAGS += $(EXTRA_LDFLAGS)

COMMON_UTILS := $(TELMI_SRC)/src/common/utils/str.c \
	$(TELMI_SRC)/src/common/utils/log.c \
	$(TELMI_SRC)/src/common/utils/file.c

SHMVAR_OBJ := $(PLATFORM_DIR)/shmvar.c
AXP_OBJ := $(PLATFORM_DIR)/axp_stub.c

CORE_CACHE ?= /home/funkyfoenky/telmi-emu-cores
HOST_DIR ?= /home/funkyfoenky/r36s-helloworld-build/buildroot-r36s/output/host
CORES_STAGING := $(TELMI_R36_DIR)/staging/$(TELMI_PROFILE)/opt/telmi/lib/cores

# Apres chaque binaire : miroir vers staging/opt (Buildroot / scripts legacy)
define mirror_legacy
	@mkdir -p $(STAGING_LEGACY)
	@cp -a $(STAGING)/$(1) $(STAGING_LEGACY)/$(1)
endef

.PHONY: all clean install dirs libretro_cores profile-stamp

all: dirs profile-stamp axp bootScreen storyTeller chargingState batmon sdlprobe sdlprobe-fb gambatte_sdl telmi_lr libretro_cores
	@echo "OK profil=$(TELMI_PROFILE) -> $(STAGING)"

dirs:
	@mkdir -p $(STAGING) $(STAGING_LEGACY) $(STAGING_VER) $(CORES_STAGING)

profile-stamp: dirs
	@echo -n "$(TELMI_PROFILE)" > $(STAGING_VER)/profile.txt
	@mkdir -p $(TELMI_R36_DIR)/staging/opt/telmi/telmiVersion
	@echo -n "$(TELMI_PROFILE)" > $(TELMI_R36_DIR)/staging/opt/telmi/telmiVersion/profile.txt

axp: $(AXP_OBJ)
	$(CC) $(CFLAGS) -o $(STAGING)/axp $(AXP_OBJ)
	$(STRIP) $(STAGING)/axp
	$(call mirror_legacy,axp)

# Splash sans SDL (fb0 + libpng) — ne depend pas de Mesa/kmsdrm
bootScreen: $(PLATFORM_DIR)/bootScreen.c $(COMMON_UTILS)
	$(CC) $(CFLAGS) -o $(STAGING)/bootScreen $^ $(EXTRA_LDFLAGS) -lpng -lz -lpthread -lm
	$(STRIP) $(STAGING)/bootScreen
	$(call mirror_legacy,bootScreen)

# Probe fb0 seul
sdlprobe-fb: $(PLATFORM_DIR)/sdlprobe.c
	$(CC) $(CFLAGS) -o $(STAGING)/sdlprobe-fb $(PLATFORM_DIR)/sdlprobe.c $(EXTRA_LDFLAGS)
	$(STRIP) $(STAGING)/sdlprobe-fb
	$(call mirror_legacy,sdlprobe-fb)

# Probe fb0 + SDL (diagnostic segfault kmsdrm)
sdlprobe: $(PLATFORM_DIR)/sdlprobe.c
	$(CC) $(CFLAGS) -DWITH_SDL -o $(STAGING)/sdlprobe $(PLATFORM_DIR)/sdlprobe.c \
		$(EXTRA_LDFLAGS) -lSDL2
	$(STRIP) $(STAGING)/sdlprobe
	$(call mirror_legacy,sdlprobe)

# Emulateur GB (Peanut-GB) — fb0 + son QueueAudio
gambatte_sdl: $(PLATFORM_DIR)/gbemu/gbemu.c \
	$(PLATFORM_DIR)/gbemu/peanut_gb.h \
	$(PLATFORM_DIR)/gbemu/minigb_apu.c \
	$(PLATFORM_DIR)/gbemu/minigb_apu.h
	$(CC) $(CFLAGS) -O3 -I$(PLATFORM_DIR)/gbemu -I$(PLATFORM_DIR) \
		-DENABLE_SOUND=1 -DMINIGB_APU_AUDIO_FORMAT_S16SYS \
		-DAUDIO_SAMPLE_RATE=22050 -DPEANUT_GB_HIGH_LCD_ACCURACY=0 \
		-DPEANUT_GB_12_COLOUR=0 \
		-o $(STAGING)/gambatte_sdl \
		$(PLATFORM_DIR)/gbemu/gbemu.c \
		$(PLATFORM_DIR)/gbemu/minigb_apu.c \
		$(EXTRA_LDFLAGS) -lSDL2 -lpthread -lm
	$(STRIP) $(STAGING)/gambatte_sdl
	$(call mirror_legacy,gambatte_sdl)

# Frontend libretro (GBC / GBA / NES / MD / SNES / PSX)
telmi_lr: $(PLATFORM_DIR)/libretro/telmi_lr.c \
	$(PLATFORM_DIR)/libretro/libretro.h
	$(CC) $(CFLAGS) -O3 -I$(PLATFORM_DIR)/libretro -I$(PLATFORM_DIR) \
		-o $(STAGING)/telmi_lr \
		$(PLATFORM_DIR)/libretro/telmi_lr.c \
		$(EXTRA_LDFLAGS) -lSDL2 -ldl -lpthread -lm
	$(STRIP) $(STAGING)/telmi_lr
	$(call mirror_legacy,telmi_lr)

# Cores libretro (sources dans CORE_CACHE, hors tree Windows)
libretro_cores:
	@chmod +x "$(TELMI_R36_DIR)/scripts/build-libretro-cores.sh" 2>/dev/null || true
	HOST_DIR="$(HOST_DIR)" CORE_CACHE="$(CORE_CACHE)" \
	OUT_DIR="$(CORES_STAGING)" \
	bash "$(TELMI_R36_DIR)/scripts/build-libretro-cores.sh"
	@mkdir -p $(TELMI_R36_DIR)/staging/opt/telmi/lib/cores
	@if [ -d "$(CORES_STAGING)" ]; then \
		rsync -a "$(CORES_STAGING)/" "$(TELMI_R36_DIR)/staging/opt/telmi/lib/cores/" 2>/dev/null || \
		cp -a "$(CORES_STAGING)/." "$(TELMI_R36_DIR)/staging/opt/telmi/lib/cores/" 2>/dev/null || true; \
	fi

storyTeller: dirs profile-stamp $(PLATFORM_DIR)/storyTeller/storyTeller.c \
	$(TELMI_SRC)/include/cjson/cJSON.c \
	$(COMMON_UTILS) $(SHMVAR_OBJ)
	$(CC) $(CFLAGS) -I$(TELMI_SRC)/src/storyTeller \
		-o $(STAGING)/storyTeller \
		$(PLATFORM_DIR)/storyTeller/storyTeller.c \
		$(TELMI_SRC)/include/cjson/cJSON.c \
		$(COMMON_UTILS) $(SHMVAR_OBJ) \
		$(LDFLAGS)
	$(STRIP) $(STAGING)/storyTeller
	$(call mirror_legacy,storyTeller)
	@echo "storyTeller profil=$(TELMI_PROFILE)"

chargingState: $(TELMI_SRC)/src/chargingState/chargingState.c \
	$(TELMI_SRC)/include/cjson/cJSON.c $(COMMON_UTILS)
	$(CC) $(CFLAGS) -I$(TELMI_SRC)/src/chargingState \
		-o $(STAGING)/chargingState \
		$(TELMI_SRC)/src/chargingState/chargingState.c \
		$(TELMI_SRC)/include/cjson/cJSON.c \
		$(COMMON_UTILS) $(LDFLAGS) -lSDL2 -lSDL2_ttf -lSDL2_image
	$(STRIP) $(STAGING)/chargingState
	$(call mirror_legacy,chargingState)

batmon: $(PLATFORM_DIR)/batmon_simple.c
	$(CC) $(CFLAGS) -o $(STAGING)/batmon $(PLATFORM_DIR)/batmon_simple.c
	$(STRIP) $(STAGING)/batmon
	$(call mirror_legacy,batmon)

install: all
	@echo "Binaires -> $(STAGING) (miroir $(STAGING_LEGACY))"

clean:
	rm -f $(STAGING)/axp $(STAGING)/bootScreen $(STAGING)/storyTeller \
		$(STAGING)/chargingState $(STAGING)/batmon $(STAGING)/sdlprobe \
		$(STAGING)/sdlprobe-fb $(STAGING)/gambatte_sdl $(STAGING)/telmi_lr
