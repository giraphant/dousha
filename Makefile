APP_NAME    := Dousha
BUILD_DIR   := .build
RELEASE_DIR := $(BUILD_DIR)/release
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := /Applications
DIST_DIR    := $(BUILD_DIR)/dist
DIST_APP    := $(DIST_DIR)/$(APP_NAME).app
DIST_DMG    := $(DIST_DIR)/$(APP_NAME).dmg
DMG_STAGING := $(BUILD_DIR)/dmg-staging

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

.PHONY: all build run install dist notarize release clean reset-perms

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
		CODESIGN_OPTIONS="--options runtime --timestamp" \
		CODESIGN_ENTITLEMENTS="--entitlements Resources/Dousha.entitlements"
	@rm -rf "$(DIST_DIR)" "$(DMG_STAGING)"
	@mkdir -p "$(DIST_DIR)" "$(DMG_STAGING)"
	@cp -R "$(APP_BUNDLE)" "$(DIST_APP)"
	@cp -R "$(APP_BUNDLE)" "$(DMG_STAGING)/$(APP_NAME).app"
	@ln -s /Applications "$(DMG_STAGING)/Applications"
	@hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_STAGING)" -ov -format UDZO "$(DIST_DMG)" >/dev/null
	@codesign --force --sign "$(DEVELOPER_ID_IDENTITY)" --timestamp "$(DIST_DMG)"
	@echo "Packaged $(DIST_DMG)"

notarize: dist
	xcrun notarytool submit "$(DIST_DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DIST_DMG)"
	@echo "Notarized and stapled $(DIST_DMG)"

# One-shot release: assumes Info.plist already bumped to $(VERSION) and committed.
# Notarizes the DMG, tags HEAD, and publishes a GitHub release with the DMG attached.
release:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make release VERSION=0.1.0"; exit 1; fi
	@plist_v=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist); \
	if [ "$$plist_v" != "$(VERSION)" ]; then \
		echo "ERROR: Info.plist version $$plist_v != VERSION=$(VERSION). Bump Info.plist first."; exit 1; \
	fi
	@if ! git diff-index --quiet HEAD --; then \
		echo "ERROR: working tree has uncommitted changes. Commit the version bump first."; exit 1; \
	fi
	@$(MAKE) notarize
	gh release create "v$(VERSION)" "$(DIST_DMG)" --title "v$(VERSION)" --generate-notes
	@echo "Release v$(VERSION) published. Tag pushed by gh."

clean:
	rm -rf $(BUILD_DIR)

reset-perms:
	tccutil reset Microphone com.dousha.app || true
	tccutil reset SpeechRecognition com.dousha.app || true
	tccutil reset Accessibility com.dousha.app || true
