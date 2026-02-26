BUILDER_IMAGE=patina-qemu-builder
SECURE_FLASH0_FILE=$(PWD)/Build/QemuSbsaPkg/DEBUG_GCC5/FV/SECURE_FLASH0.fd
QEMU_EFI_FILE=$(PWD)/Build/QemuSbsaPkg/DEBUG_GCC5/FV/QEMU_EFI.fd
# Set this environment variable to override the default rust secure partition directory, e.g. to a haf-ec-service directory
RUST_SP_DIR ?= Features/FFA/FfaFeaturePkg/SecurePartitions/MsSecurePartitionRust
RUST_SP_FILE_BASE=Build/rust-secure-partition.bin
COMMON_BUILDER_FLAGS=\
	-v $(PWD):/workspace \
	-v ~/.gitconfig:/root/.gitconfig \
	-v $(PWD)/Build/root-builder-cache:/root/.cache \
	-e RUST_SP_BINARY_PATH=/workspace/$(RUST_SP_FILE_BASE) \
	-w /workspace

.PHONY: build-rust-sp
build-rust-sp:
	echo "Building rust secure partition from $(RUST_SP_DIR)"
	cd $(RUST_SP_DIR) && cargo objcopy --release --target=aarch64-unknown-none -- -O binary $(PWD)/$(RUST_SP_FILE_BASE)

.PHONY: build-builder-image
build-builder-image:
	docker build -f .devcontainer/Dockerfile -t $(BUILDER_IMAGE) .

.PHONY: stuart-setup
stuart-setup: build-builder-image
	docker run $(COMMON_BUILDER_FLAGS) $(BUILDER_IMAGE) stuart_setup -c Platforms/QemuSbsaPkg/PlatformBuild.py

.PHONY: stuart-update
stuart-update: build-builder-image
	docker run $(COMMON_BUILDER_FLAGS) $(BUILDER_IMAGE) stuart_update -c Platforms/QemuSbsaPkg/PlatformBuild.py

# Build the entire firmware
# Generates SECURE_FLASH0_FILE and QEMU_EFI_FILE
.PHONY: stuart-build
stuart-build: build-builder-image build-rust-sp
	docker run $(COMMON_BUILDER_FLAGS) $(BUILDER_IMAGE) \
		stuart_build -c Platforms/QemuSbsaPkg/PlatformBuild.py \
		HAF_TFA_BUILD=TRUE \
		PATCH_TFA=FALSE \
		RUST_SP_BINARY_PATH=$(RUST_SP_FILE_BASE)

# Patch the rust secure partition into the SECURE_FLASH0.fd file, without rebuilding the entire firmware
# Useful for fast iteration on the rust secure partition code
# Works by looking for the first 120 bytes of the rust secure partition binary (which tends to be a fixed value)
# and then patching the SECURE_FLASH0.fd file at the offset of the first occurrence of those bytes
#
# Depends on having `bgrep` available - https://github.com/tmbinc/bgrep (or `brew install bgrep` on macos)
.PHONY: patch-flash0
patch-flash0: build-rust-sp
	@set -ex; \
	export TMPFILE_NAME=$$(mktemp); \
	echo "TMPFILE_NAME: $$TMPFILE_NAME"; \
	cp $(SECURE_FLASH0_FILE) $$TMPFILE_NAME; \
	export OFFSET=$$(bgrep $$(xxd -p $(PWD)/$(RUST_SP_FILE_BASE) | head -n 4 | tr -d '\n') $(SECURE_FLASH0_FILE) | cut -d ' ' -f 2); \
	if [ -z "$$OFFSET" ] || [ "$$OFFSET" = "0" ] || [ "$$OFFSET" = "00000000" ]; then \
		echo "ERROR: failed to locate rust secure partition pattern in $(SECURE_FLASH0_FILE) (OFFSET='$$OFFSET')"; \
		exit 1; \
	fi; \
	export OFFSET_DEC=$$(printf '%d' 0x$$OFFSET); \
	dd if=$(PWD)/$(RUST_SP_FILE_BASE) of=$$TMPFILE_NAME bs=1 seek=$$OFFSET_DEC conv=notrunc 2>/dev/null; \
	cp $$TMPFILE_NAME $(SECURE_FLASH0_FILE); \
	echo Patched $(SECURE_FLASH0_FILE) at offset $$OFFSET_DEC

.PHONY: run-qemu
run-qemu:
	truncate -s0 console.log
	qemu-system-aarch64 \
		-net none \
		-display none \
		-semihosting-config enable=on,target=native \
		-m 2048 \
		-machine sbsa-ref \
		-cpu max,sve=off,sme=off \
		-smp 4 -global driver=cfi.pflash01,property=secure,value=on \
		-drive if=pflash,format=raw,unit=0,file=$(SECURE_FLASH0_FILE) \
		-drive if=pflash,format=raw,unit=1,file=$(QEMU_EFI_FILE),readonly=on \
		-device qemu-xhci,id=usb \
		-device usb-tablet,id=input0,bus=usb.0,port=1 \
		-device usb-kbd,id=input1,bus=usb.0,port=2 \
		-smbios type=0,vendor="Patina",version="patina-sbsa-v0.1.1-2-g8625168c",date=01/13/2026,uefi=on \
		-smbios type=1,manufacturer=OpenDevicePartnership \
		-smbios type=3,manufacturer=OpenDevicePartnership \
		-serial stdio \
		-serial file:secure.log \
		-serial file:secure_mm.log \
		| tee console.log || test $$? -eq 1