SUDO ?= sudo

.PHONY: smoke clean diag ipk

smoke:
	$(SUDO) ./scripts/smoke-test.sh

clean:
	$(SUDO) CLEAN_LOGS=1 ./reproducer/netns-lab.sh clean

# Collects diagnostics on the host (or OpenWrt if pointed via ssh). Override OUT_DIR/LAN_IF/WAN_IF as needed.
diag:
	$(SUDO) ./diagnostics/collect.sh

ipk:
	./scripts/build-ipk.sh
