PLATFORM := r36s
INCLUDE_CJSON := 1
INCLUDE_SHMVAR := 1

CC ?= gcc
STRIP ?= strip

CFLAGS += -Wall -O2 -std=gnu18 -DPLATFORM_R36S
LDFLAGS += -lpthread -lm -lSDL2 -lSDL2_image -lSDL2_ttf -lSDL2_mixer -lSDL2_gfx
