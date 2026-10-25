# Host-compiled unit tests for the parts of flipper/src that do not touch the
# Flipper SDK. Every test_*.c becomes its own binary linked against every
# source in ../src that includes no Flipper header. Tests read the shared
# protocol fixtures through fixture.h (PROTOCOL_DIR).
#
#   make test            build and run all tests
#   make clean

CC ?= cc
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -O1 -g
SANITIZE ?= -fsanitize=address,undefined -fno-omit-frame-pointer
CPPFLAGS += -I../src -I. -DPROTOCOL_DIR='"$(abspath $(CURDIR)/../../protocol)"'

BUILD := build
FLIPPER_HEADERS := '\#include <(furi|furi_hal|gui|nfc|lib/nfc|storage|notification|input|dialogs|toolbox|applications)'
ALL_SRCS := $(shell find ../src -name '*.c' | sort)
HOST_SRCS := $(if $(ALL_SRCS),$(shell grep -L -E $(FLIPPER_HEADERS) $(ALL_SRCS)))
HOST_OBJS := $(patsubst ../src/%.c,$(BUILD)/src/%.o,$(HOST_SRCS))
TESTS := $(patsubst %.c,$(BUILD)/%,$(sort $(wildcard test_*.c)))

.PHONY: test clean
.SECONDARY:
.DEFAULT_GOAL := test

test: $(TESTS)
	@set -e; for t in $(TESTS); do ./$$t; done

$(BUILD)/src/%.o: ../src/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(SANITIZE) -MMD -MP -c $< -o $@

$(BUILD)/test_%.o: test_%.c
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(SANITIZE) -MMD -MP -c $< -o $@

$(BUILD)/test_%: $(BUILD)/test_%.o $(HOST_OBJS)
	$(CC) $(CFLAGS) $(SANITIZE) $^ -o $@

clean:
	rm -rf $(BUILD)

-include $(shell find $(BUILD) -name '*.d' 2>/dev/null)
