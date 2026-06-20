APP_NAME := AulaGifUploader
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
APP_BIN := $(APP_DIR)/Contents/MacOS/$(APP_NAME)
PROBE_BIN := $(APP_DIR)/Contents/MacOS/F75Probe
ICON := Resources/AppIcon.icns

.PHONY: all clean app probe icon

all: icon probe app

icon: $(ICON)

probe: $(BUILD_DIR)/F75Probe

app: $(APP_BIN) $(PROBE_BIN) $(APP_DIR)/Contents/Info.plist $(APP_DIR)/Contents/Resources/AppIcon.icns
	codesign --force --deep --sign - $(APP_DIR)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/F75Probe: Sources/F75Probe/main.m | $(BUILD_DIR)
	clang -fobjc-arc -Wall -Wextra -framework CoreGraphics -framework Foundation -framework ImageIO -framework IOKit -o $@ $<

$(APP_BIN): Sources/AulaGifUploader/main.m | $(BUILD_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS
	clang -fobjc-arc -Wall -Wextra -framework AppKit -framework Foundation -framework ImageIO -framework UniformTypeIdentifiers -o $@ $<

$(PROBE_BIN): $(BUILD_DIR)/F75Probe | $(BUILD_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS
	cp $< $@

$(APP_DIR)/Contents/Info.plist: Info.plist | $(BUILD_DIR)
	mkdir -p $(APP_DIR)/Contents
	cp $< $@

$(APP_DIR)/Contents/Resources/AppIcon.icns: $(ICON) | $(BUILD_DIR)
	mkdir -p $(APP_DIR)/Contents/Resources
	cp $< $@

$(ICON): Resources/AppIconSource.png Scripts/make_icon.py
	python3 Scripts/make_icon.py Resources/AppIconSource.png Resources/AppIcon.icns

clean:
	rm -rf $(BUILD_DIR) Resources/AppIcon.iconset Resources/AppIcon.icns
