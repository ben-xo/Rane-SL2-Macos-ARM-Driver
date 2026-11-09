CC = clang
ARCH = -arch arm64 -arch x86_64
CFLAGS = -fobjc-arc -O2
# make plugin DEBUG=1 builds the driver with its streaming diagnostics and its debug commands
# (tools/latency/bin/sl2dbg: input safety offset, test hooks); make install DEBUG=1 also installs it
PLUGIN_DEFS = $(if $(DEBUG),-DSL2_DEBUG=1)

all: plugin api panel dump flash

plugin:
	$(CC) $(ARCH) -bundle $(CFLAGS) $(PLUGIN_DEFS) -framework Foundation -framework CoreAudio -framework IOKit -framework IOUSBHost plugin/SL2Device.m -o SL2Device

# build the driver and install it into the installed driver bundle, then restart coreaudiod
# (tools/install-sl2.sh; asks for your password). The release package must be installed first.
# make install DEBUG=1 installs a debug build; make install puts a release build back.
install: plugin
	sudo tools/install-sl2.sh

api:
	$(CC) $(ARCH) -dynamiclib $(CFLAGS) -install_name /Library/Frameworks/SL2Api.framework/Versions/A/SL2Api -current_version 1.1.0 -compatibility_version 1.0.0 -framework Foundation -framework CoreAudio -framework IOKit tools/SL2Api.m -o SL2Api

panel:
	$(CC) $(ARCH) $(CFLAGS) -framework Foundation -framework CoreAudio -framework IOKit tools/sl2panel.m -o sl2panel

dump:
	$(CC) $(ARCH) $(CFLAGS) -framework Foundation -framework CoreAudio tools/sl2dump.m tools/SL2Passthrough.m -o sl2dump

# sl2apitest: checks SL2Api as Serato DJ Pro 2.5.5 uses it (run the x86_64 slice with arch -x86_64)
apitest:
	$(CC) $(ARCH) -O2 tools/sl2apitest.c -o sl2apitest

flash:
	$(CC) $(ARCH) $(CFLAGS) -Itools -framework Foundation -framework CoreAudio -framework IOKit -framework IOUSBHost tools/firmware/sl2flash.m tools/SL2Passthrough.m -o sl2flash

# latency and glitch test tools (tools/latency/README.md), built into tools/latency/bin
LATENCY_TOOLS = rtlat sinetest chtone chrec devprobe setrate sl2dbg volctl
latency: $(addprefix tools/latency/bin/,$(LATENCY_TOOLS))

tools/latency/bin/%: tools/latency/%.c tools/latency/common.h
	@mkdir -p tools/latency/bin
	$(CC) -O2 -framework CoreAudio -framework CoreFoundation -framework AudioToolbox $< -o $@

# the hardware tests in one run (tools/hwtest.sh), on the installed driver with a box attached
# (install a debug build first, make install DEBUG=1, to also run the debug-only tests):
#   make hwtest ARGS="--loopback"   with the loopback cable in; add --no-physical to skip the steps
#                                   that need someone at the box (switch, unplug and replug)
hwtest: panel apitest latency
	tools/hwtest.sh $(ARGS)

clean:
	rm -f SL2Device SL2Api sl2panel sl2dump sl2flash sl2apitest
	rm -rf tools/latency/bin

.PHONY: all plugin install api panel dump flash apitest latency hwtest clean
