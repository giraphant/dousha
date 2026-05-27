APP_NAME    := Dousha
BUILD_DIR   := .build
RELEASE_DIR := $(BUILD_DIR)/release
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := /Applications

# Stable code-signing identity so TCC grants survive rebuilds.
# Falls back to ad-hoc if the cert isn't in the keychain (CI / fresh clone).
# To set up the cert locally see docs/dev-codesign.md.
CODESIGN_IDENTITY ?= Dousha Local Dev

.PHONY: all build run install clean reset-perms

all: build

build:
	swift build -c release
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(RELEASE_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@if security find-certificate -c "$(CODESIGN_IDENTITY)" >/dev/null 2>&1; then \
		codesign --force --deep --sign "$(CODESIGN_IDENTITY)" $(APP_BUNDLE); \
		echo "Built $(APP_BUNDLE) (signed with: $(CODESIGN_IDENTITY))"; \
	else \
		codesign --force --deep --sign - $(APP_BUNDLE); \
		echo "Built $(APP_BUNDLE) (ad-hoc signed — TCC grants will reset on every rebuild; see docs/dev-codesign.md)"; \
	fi

run: build
	open $(APP_BUNDLE)

install: build
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R $(APP_BUNDLE) "$(INSTALL_DIR)/"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

clean:
	rm -rf $(BUILD_DIR)

reset-perms:
	tccutil reset Microphone com.dousha.app || true
	tccutil reset SpeechRecognition com.dousha.app || true
	tccutil reset Accessibility com.dousha.app || true
