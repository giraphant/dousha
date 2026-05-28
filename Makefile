APP_NAME    := Dousha
BUILD_DIR   := .build
RELEASE_DIR := $(BUILD_DIR)/release
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := /Applications
DIST_DIR    := $(BUILD_DIR)/dist
DIST_APP    := $(DIST_DIR)/$(APP_NAME).app
DIST_ZIP    := $(DIST_DIR)/$(APP_NAME).zip

# Stable code-signing identity so TCC grants survive rebuilds.
# Falls back to ad-hoc if the cert isn't in the keychain (CI / fresh clone).
# To set up the cert locally see docs/dev-codesign.md.
CODESIGN_IDENTITY ?= Dousha Local Dev
CODESIGN_OPTIONS  ?=
CODESIGN_ENTITLEMENTS ?=

# Developer ID distribution. Requires a matching private key in the login
# keychain. For notarization, first store credentials with:
# xcrun notarytool store-credentials "$(NOTARY_PROFILE)" --apple-id ... --team-id ... --password ...
DEVELOPER_ID_IDENTITY ?= Developer ID Application: <Your Name> (<TEAMID>)
NOTARY_PROFILE ?= DoushaNotaryProfile

.PHONY: all build run install dist notarize clean reset-perms

all: build

build:
	swift build -c release
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(RELEASE_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@if security find-identity -v -p codesigning | grep -F "$(CODESIGN_IDENTITY)" >/dev/null 2>&1; then \
		codesign --force --deep $(CODESIGN_OPTIONS) $(CODESIGN_ENTITLEMENTS) --sign "$(CODESIGN_IDENTITY)" $(APP_BUNDLE); \
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

dist:
	@$(MAKE) build \
		CODESIGN_IDENTITY="$(DEVELOPER_ID_IDENTITY)" \
		CODESIGN_OPTIONS="--options runtime --timestamp"
	@rm -rf "$(DIST_DIR)"
	@mkdir -p "$(DIST_DIR)"
	@cp -R "$(APP_BUNDLE)" "$(DIST_APP)"
	@ditto -c -k --keepParent "$(DIST_APP)" "$(DIST_ZIP)"
	@echo "Packaged $(DIST_ZIP)"

notarize: dist
	xcrun notarytool submit "$(DIST_ZIP)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DIST_APP)"
	@ditto -c -k --keepParent "$(DIST_APP)" "$(DIST_ZIP)"
	@echo "Notarized and stapled $(DIST_APP)"
	@echo "Repackaged $(DIST_ZIP)"

clean:
	rm -rf $(BUILD_DIR)

reset-perms:
	tccutil reset Microphone com.dousha.app || true
	tccutil reset SpeechRecognition com.dousha.app || true
	tccutil reset Accessibility com.dousha.app || true
