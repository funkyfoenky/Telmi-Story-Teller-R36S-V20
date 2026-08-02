################################################################################
# telmi-r36s — applications TelmiOS cross-compilees pour R36S
################################################################################

TELMI_R36S_PKGDIR = $(dir $(lastword $(MAKEFILE_LIST)))
TELMI_R36S_SITE = $(TELMI_R36S_PKGDIR)/../../../..
TELMI_R36S_SITE_METHOD = local
TELMI_R36S_LICENSE = GPL-3.0
TELMI_R36S_DEPENDENCIES = sdl2 sdl2_image sdl2_ttf sdl2_mixer sdl2_gfx libpng

# Buildroot (SITE_METHOD=local) rsync le SITE via OVERRIDE — exclure les gros artefacts
# sinon rsync copie les .img (dizaines de Go) depuis /mnt/c et semble "bloque".
TELMI_R36S_OVERRIDE_SRCDIR_RSYNC_EXCLUSIONS = \
	--exclude output/ \
	--exclude cache/ \
	--exclude staging/ \
	--exclude .tools/ \
	--exclude backups/ \
	--exclude '*.img' \
	--exclude '*.tar'

# Ne pas recopier output/ (images .img 4 Go+) ni caches dans output/build/
# SITE_METHOD=local : Buildroot re-rsync le SITE a chaque build.
# Les sources Miyoo restent hors SITE → passees via TELMI_SRC au make.
define TELMI_R36S_EXTRACT_CMDS
	mkdir -p $(@D)
	rsync -a --delete \
		--exclude 'output/' \
		--exclude 'cache/' \
		--exclude 'staging/' \
		--exclude '.tools/' \
		--exclude 'backups/' \
		--exclude '.git/' \
		--exclude '*.img' \
		--exclude '*.tar' \
		$($(PKG)_SITE)/ $(@D)/
endef

define TELMI_R36S_BUILD_CMDS
	$(MAKE) -C $(@D)/build \
		CC=$(TARGET_CC) \
		CXX=$(TARGET_CXX) \
		STRIP=$(TARGET_STRIP) \
		TELMI_SRC=$($(PKG)_SITE)/../Telmi-story-teller-1.10.1 \
		HOST_DIR=$(HOST_DIR) \
		CORE_CACHE=/home/funkyfoenky/telmi-emu-cores \
		EXTRA_CFLAGS="$(TARGET_CFLAGS) -I$(STAGING_DIR)/usr/include/SDL2" \
		EXTRA_LDFLAGS="$(TARGET_LDFLAGS) -L$(STAGING_DIR)/usr/lib"
endef

define TELMI_R36S_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/opt/telmi/bin $(TARGET_DIR)/opt/telmi/res \
		$(TARGET_DIR)/opt/telmi/config $(TARGET_DIR)/opt/telmi/lib/cores
	rsync -a $(@D)/staging/opt/telmi/bin/ $(TARGET_DIR)/opt/telmi/bin/
	if [ -d "$(@D)/staging/opt/telmi/lib/cores" ]; then \
		rsync -a $(@D)/staging/opt/telmi/lib/cores/ $(TARGET_DIR)/opt/telmi/lib/cores/; \
	fi
	if [ -d "$(@D)/assets/res" ]; then \
		rsync -a $(@D)/assets/res/ $(TARGET_DIR)/opt/telmi/res/; \
	fi
	if [ -d "$(@D)/assets/config" ]; then \
		rsync -a $(@D)/assets/config/ $(TARGET_DIR)/opt/telmi/config/; \
	fi
	mkdir -p $(TARGET_DIR)/telmi $(TARGET_DIR)/mnt $(TARGET_DIR)/opt/telmi/telmiVersion
	ln -sf /telmi $(TARGET_DIR)/mnt/SDCARD
	echo -n "v1.10.1" > $(TARGET_DIR)/opt/telmi/telmiVersion/version.txt
	chmod +x $(TARGET_DIR)/opt/telmi/bin/*
	# Evite le crash panfrost sur noyau vendor 5.10 : ne garder que swrast
	for d in panfrost_dri.so rockchip_dri.so mali-dp_dri.so; do \
		if [ -f "$(TARGET_DIR)/usr/lib/dri/$$d" ]; then \
			mv -f "$(TARGET_DIR)/usr/lib/dri/$$d" "$(TARGET_DIR)/usr/lib/dri/$$d.disabled"; \
		fi; \
	done
endef

$(eval $(generic-package))
