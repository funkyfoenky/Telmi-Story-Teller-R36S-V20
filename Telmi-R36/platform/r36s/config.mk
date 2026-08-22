PLATFORM := r36s
INCLUDE_CJSON := 1
INCLUDE_SHMVAR := 1

# Profil staging : unified (defaut) | v20 | v30
# Les quirks HW sont runtime (/boot/TELMI-REV.txt) — un seul binaire.
#   make -C build TELMI_PROFILE=unified storyTeller
#   bash scripts/build-telmi-bins.sh unified
TELMI_PROFILE ?= unified

CC ?= gcc
STRIP ?= strip

CFLAGS += -Wall -O2 -std=gnu18 -DPLATFORM_R36S
# Rétrocompat macros ; ne plus brancher de quirks dessus.
ifeq ($(TELMI_PROFILE),v30)
CFLAGS += -DTELMI_PROFILE_UNIFIED -DTELMI_PROFILE_NAME=\"unified\"
else ifeq ($(TELMI_PROFILE),v20)
CFLAGS += -DTELMI_PROFILE_UNIFIED -DTELMI_PROFILE_NAME=\"unified\"
else
CFLAGS += -DTELMI_PROFILE_UNIFIED -DTELMI_PROFILE_NAME=\"unified\"
TELMI_PROFILE := unified
endif

LDFLAGS += -lpthread -lm -lSDL2 -lSDL2_image -lSDL2_ttf -lSDL2_mixer -lSDL2_gfx
