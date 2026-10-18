
.check_%:
	@command -v $* >/dev/null
	if [ $$? -ne 0 ]; then
		echo "eCapture Makefile: missing required tool $*"
		exit 1
	else
		touch $@ # avoid target rebuilds due to inexistent file
	fi


#  clang 编译器版本检测，llvm检测，
.checkver_$(CMD_CLANG): \
	| .check_$(CMD_CLANG)
#
	@echo $(shell date)
	@if [ ${CLANG_VERSION} -lt 9 ]; then
		echo -n "you MUST use clang 9 or newer, "
		echo "your current clang version is ${CLANG_VERSION}"
		exit 1
	fi
	$(CMD_TOUCH) $@ # avoid target rebuilds over and over due to inexistent file


# golang 版本检测  1.24 以上
.checkver_$(CMD_GO): \
	| .check_$(CMD_GO)
	@if [ ${GO_VERSION_MAJ} -eq 1 ]; then
		if [ ${GO_VERSION_MIN} -lt 24 ]; then
			echo -n "you MUST use golang 1.24 or newer, "
			echo "your current golang version is ${GO_VERSION}"
			exit 1
		fi
	fi
	touch $@

# bpftool version
.checkver_$(CMD_BPFTOOL): \
	| .check_$(CMD_BPFTOOL)

define allow-override
  $(if $(or $(findstring environment,$(origin $(1))),\
            $(findstring command line,$(origin $(1)))),,\
    $(eval $(1) = $(2)))
endef

define gobuild
	CGO_ENABLED=1 \
	CGO_CFLAGS='-O2 -g -gdwarf-4 -I$(CURDIR)/lib/libpcap/' \
	CGO_LDFLAGS='-O2 -g -L$(CURDIR)/lib/libpcap/ -lpcap -static' \
	GOOS=linux GOARCH=$(GOARCH) CC=$(CMD_CC_PREFIX)$(CMD_CC) \
	$(CMD_GO) build -trimpath -buildmode=pie -mod=readonly -tags '$(TARGET_TAG),netgo,ebpfassets,dynamic' -ldflags "-w -s -X 'github.com/gojue/ecapture/cli/cmd.GitVersion=$(TARGET_TAG)_$(GOARCH):$(VERSION_NUM):$(VERSION_FLAG)' -X 'github.com/gojue/ecapture/cli/cmd.ByteCodeFiles=$(BYTECODE_FILES)' -linkmode=external -extldflags -static " -o $(OUT_BIN)
	$(CMD_FILE) $(OUT_BIN)
endef


define CHECK_IS_NON_CORE
$(if $(filter $(1),$(2)),-nocore,)
endef

# build and tar
define release_tar
	$(call allow-override,CORE_PREFIX,$(call CHECK_IS_NON_CORE,$(2),nocore))
	$(call allow-override,TAR_DIR,ecapture-$(DEB_VERSION)-$(1)-$(GOARCH)$(CORE_PREFIX))
	$(call allow-override,OUT_ARCHIVE,$(OUTPUT_DIR)/$(TAR_DIR).tar.gz)
	$(CMD_MAKE) clean
	ANDROID=$(ANDROID) $(CMD_MAKE) $(2)
	# create the tar ball and checksum files
	$(CMD_MKDIR) -p $(TAR_DIR)
	$(CMD_CP) LICENSE $(TAR_DIR)/LICENSE
	$(CMD_CP) CHANGELOG.md $(TAR_DIR)/CHANGELOG.md
	$(CMD_CP) README.md $(TAR_DIR)/README.md
	$(CMD_CP) README-zh_Hans.md $(TAR_DIR)/README-zh_Hans.md
	$(CMD_CP) $(OUTPUT_DIR)/ecapture $(TAR_DIR)/ecapture
	$(CMD_TAR) -czf $(OUT_ARCHIVE) $(TAR_DIR)
endef

# Build schannel_hook.dll for Windows.
# amd64: use MinGW gcc (the only supported Windows compiler for this project).
# arm64: skip — DLL injection hooking is a safe no-op on ARM64 (see schannel_hook.c:29).
define build_schannel_hook_dll
	$(CMD_MKDIR) -p bin
	@if [ "$(MINGW_TARGET)" = "aarch64-w64-windows-gnu" ]; then \
		echo "Skipping bin/schannel_hook.dll (ARM64 — no inline hook needed; see schannel_hook.c:29)"; \
	elif command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then \
		echo "Building bin/schannel_hook.dll ($(MINGW_TARGET)) with x86_64-w64-mingw32-gcc"; \
		x86_64-w64-mingw32-gcc -shared -O2 -DSECURITY_WIN32 \
			-o bin/schannel_hook.dll $(SCHANNEL_HOOK_SRC) -lws2_32 -lsecur32; \
		ls -lh bin/schannel_hook.dll; \
	else \
		echo "ERROR: cannot build bin/schannel_hook.dll; install MinGW:"; \
		echo "  sudo apt-get install -y mingw-w64-x86-64-dev (amd64)"; \
		echo "  sudo apt-get install -y gcc-mingw-w64-aarch64-linux-gnu (arm64)"; \
		exit 1; \
	fi
endef

# Cross-compile ecapture.exe for Windows (ETW; optional pcap on amd64 when NPCAP_SDK is set).
define gobuild_windows
	$(CMD_MKDIR) -p bin
	@if [ "$(WINDOWS_GOARCH)" = "arm64" ]; then \
		if [ -n "$(NPCAP_SDK)" ]; then \
			echo "NOTE: pcap mode is not yet supported on Windows ARM64 (gopacket incompatibility)"; \
		fi; \
		echo "Building eCapture for Windows arm64 (ETW-only)"; \
		CGO_ENABLED=0 GOOS=windows GOARCH=arm64 $(CMD_GO) build \
			-tags 'windows' \
			-ldflags "-s -w -X 'github.com/gojue/ecapture/cli/cmd.GitVersion=windows_arm64:$(VERSION_NUM)' -X 'github.com/gojue/ecapture/cli/cmd.ByteCodeFiles=none'" \
			-o bin/ecapture.exe main.go; \
	elif [ -n "$(NPCAP_SDK)" ]; then \
		echo "Building eCapture for Windows amd64 (ETW + pcap)"; \
		CGO_ENABLED=1 \
		CGO_CFLAGS="-I$(NPCAP_SDK)/Include" \
		CGO_LDFLAGS="-L$(NPCAP_SDK)/Lib/x64 -lwpcap -lPacket" \
		CC='$(MINGW_CC)' \
		GOOS=windows GOARCH=amd64 $(CMD_GO) build \
			-tags 'windows,pcap' \
			-ldflags "-s -w -X 'github.com/gojue/ecapture/cli/cmd.GitVersion=windows_amd64:$(VERSION_NUM)' -X 'github.com/gojue/ecapture/cli/cmd.ByteCodeFiles=none'" \
			-o bin/ecapture.exe main.go; \
	else \
		echo "Building eCapture for Windows amd64 (ETW-only, set NPCAP_SDK to enable pcap)"; \
		CGO_ENABLED=0 GOOS=windows GOARCH=amd64 $(CMD_GO) build \
			-tags 'windows' \
			-ldflags "-s -w -X 'github.com/gojue/ecapture/cli/cmd.GitVersion=windows_amd64:$(VERSION_NUM)' -X 'github.com/gojue/ecapture/cli/cmd.ByteCodeFiles=none'" \
			-o bin/ecapture.exe main.go; \
	fi
endef

# build and zip for Windows (no eBPF, CGO_ENABLED=0)
define release_zip
	set -e
	$(call allow-override,TAR_DIR,ecapture-$(DEB_VERSION)-$(1)-$(2))
	$(call allow-override,OUT_ZIP,$(OUTPUT_DIR)/$(TAR_DIR).zip)
	$(CMD_MAKE) clean
	$(CMD_MAKE) windows CROSS_ARCH=$(2)
	$(CMD_MKDIR) -p $(TAR_DIR)
	$(CMD_CP) LICENSE $(TAR_DIR)/LICENSE
	$(CMD_CP) README.md $(TAR_DIR)/README.md
	$(CMD_CP) README-zh_Hans.md $(TAR_DIR)/README-zh_Hans.md
	test -s $(OUTPUT_DIR)/ecapture.exe
	$(CMD_CP) $(OUTPUT_DIR)/ecapture.exe $(TAR_DIR)/ecapture.exe
	@if [ "$(2)" = "amd64" ]; then \
		test -s bin/schannel_hook.dll; \
		$(CMD_CP) bin/schannel_hook.dll $(TAR_DIR)/schannel_hook.dll; \
	fi
	$(CMD_RM) -f $(OUT_ZIP)
	(cd $(TAR_DIR) && $(CMD_ZIP) -r ../$(OUT_ZIP) .)
endef
