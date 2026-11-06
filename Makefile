CC = clang
ARCH = -arch arm64 -arch x86_64
CFLAGS = -fobjc-arc -O2

all: plugin api panel dump

plugin:
	$(CC) $(ARCH) -bundle $(CFLAGS) -framework Foundation -framework CoreAudio -framework IOKit -framework IOUSBHost plugin/SL2Device.m -o SL2Device

api:
	$(CC) $(ARCH) -dynamiclib $(CFLAGS) -install_name /Library/Frameworks/SL2Api.framework/Versions/A/SL2Api -current_version 1.1.0 -compatibility_version 1.0.0 -framework Foundation -framework CoreAudio -framework IOKit tools/SL2Api.m -o SL2Api

panel:
	$(CC) $(ARCH) $(CFLAGS) -framework Foundation -framework CoreAudio tools/sl2panel.m -o sl2panel

dump:
	$(CC) $(ARCH) $(CFLAGS) -framework Foundation -framework CoreAudio tools/sl2dump.m -o sl2dump

clean:
	rm -f SL2Device SL2Api sl2panel sl2dump

.PHONY: all plugin api panel dump clean
