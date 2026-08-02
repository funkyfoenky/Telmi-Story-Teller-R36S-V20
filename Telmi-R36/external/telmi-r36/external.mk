BR2_EXTERNAL_TELMI_R36_PATH = $(dir $(lastword $(MAKEFILE_LIST)))

include $(sort $(wildcard $(BR2_EXTERNAL_TELMI_R36_PATH)/package/*/*.mk))
