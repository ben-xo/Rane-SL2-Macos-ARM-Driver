CC = clang
ARCH = -arch arm64 -arch x86_64
CFLAGS = -fobjc-arc -O2
# make plugin DEBUG=1 builds the driver with its streaming diagnostics and debug commands
PLUGIN_DEFS = $(if $(DEBUG),-DSL2_DEBUG=1)

all: plugin api panel dump flash

plugin:
	$(CC) $(ARCH) -bundle $(CFLAGS) $(PLUGIN_DEFS) -framework Foundation -framework CoreAudio -framework IOKit -framework IOUSBHost plugin/SL2Device.m -o SL2Device

api:
	$(CC) $(ARCH) -dynamiclib $(CFLAGS) -install_name /Library/Frameworks/SL2Api.framework/Versions/A/SL2Api -current_version 1.1.0 -compatibility_version 1.0.0 -framework Foundation -framework CoreAudio -framework IOKit tools/SL2Api.m -o SL2Api

panel:
	$(CC) $(ARCH) $(CFLAGS) -framework Foundation -framework CoreAudio -framework IOKit tools/sl2panel.m -o sl2panel

dump:
	$(CC) $(ARCH) $(CFLAGS) -framework Foundation -framework CoreAudio tools/sl2dump.m tools/SL2Passthrough.m -o sl2dump

flash:
	$(CC) $(ARCH) $(CFLAGS) -Itools -framework Foundation -framework CoreAudio -framework IOKit -framework IOUSBHost tools/firmware/sl2flash.m tools/SL2Passthrough.m -o sl2flash

# latency and glitch test tools (tools/latency/README.md), built into tools/latency/bin
LATENCY_TOOLS = rtlat sinetest chtone chrec devprobe setrate sl2dbg
latency: $(addprefix tools/latency/bin/,$(LATENCY_TOOLS))

tools/latency/bin/%: tools/latency/%.c
	@mkdir -p tools/latency/bin
	$(CC) -O2 -framework CoreAudio -framework CoreFoundation $< -o $@

clean:
	rm -f SL2Device SL2Api sl2panel sl2dump sl2flash
	rm -rf tools/latency/bin

.PHONY: all plugin api panel dump flash latency clean
