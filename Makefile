.PHONY: build app run clean

APP_NAME := Agent Browser
BUNDLE := AgentBrowser.app
BUILD_DIR := .build/debug

build:
	swift build

app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(BUNDLE)/Contents/MacOS"
	@mkdir -p "$(BUNDLE)/Contents/Resources"
	@cp Info.plist "$(BUNDLE)/Contents/"
	@cp "$(BUILD_DIR)/AgentBrowser" "$(BUNDLE)/Contents/MacOS/"
	@# Copy SPM bundle resources if they exist
	@if [ -d "$(BUILD_DIR)/AgentBrowser_AgentBrowser.bundle" ]; then \
		cp -R "$(BUILD_DIR)/AgentBrowser_AgentBrowser.bundle" "$(BUNDLE)/Contents/Resources/"; \
	fi
	@echo "Built $(BUNDLE)"

run: app
	@open "$(BUNDLE)"

clean:
	swift package clean
	rm -rf "$(BUNDLE)"
