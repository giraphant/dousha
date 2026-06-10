APP_NAME    := Dousha
BUILD_DIR   := .build
RELEASE_DIR := $(BUILD_DIR)/release
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := /Applications
DIST_DIR    := $(BUILD_DIR)/dist
DIST_APP    := $(DIST_DIR)/$(APP_NAME).app
DIST_DMG    := $(DIST_DIR)/$(APP_NAME).dmg
DMG_STAGING := $(BUILD_DIR)/dmg-staging

# Homebrew tap that ships the cask. `make release` bumps the cask here so
# users can `brew upgrade --cask dousha`.
TAP_REPO  ?= giraphant/homebrew-tap
CASK_PATH := Casks/dousha.rb

# Per-developer signing config lives in Makefile.local (gitignored). It
# defines DEVELOPER_ID_IDENTITY and NOTARY_PROFILE for your Apple account.
# If absent, the public defaults below act as placeholders and the codesign
# step falls back to ad-hoc — see AGENTS.md release workflow for setup.
-include Makefile.local

# Single signing identity for both local dev installs and release DMGs.
# Same cert + team identifier means TCC grants persist across `make install`
# and `make release`, since the TCC csreq is anchored to the team ID.
DEVELOPER_ID_IDENTITY ?= Developer ID Application: <Your Name> (<TEAMID>)
NOTARY_PROFILE        ?= <YourNotaryProfile>

CODESIGN_IDENTITY     ?= $(DEVELOPER_ID_IDENTITY)
CODESIGN_OPTIONS      ?= --options runtime
CODESIGN_ENTITLEMENTS ?= --entitlements Resources/Dousha.entitlements

.PHONY: all build run install dist notarize release update-cask clean reset-perms

all: build

build:
	swift build -c release
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(RELEASE_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@cp Resources/MenuIcon.png $(APP_BUNDLE)/Contents/Resources/MenuIcon.png
	@cp -R Resources/*.lproj $(APP_BUNDLE)/Contents/Resources/
	@# The repo lives under ~/Documents, which iCloud/FileProvider decorates
	@# with quarantine/provenance/FinderInfo xattrs; cp -R drags them into the
	@# bundle and codesign rejects such "detritus" (broke the 0.4.0 notarize).
	@xattr -cr $(APP_BUNDLE)
	@if security find-identity -v -p codesigning | grep -F "$(CODESIGN_IDENTITY)" >/dev/null 2>&1; then \
		codesign --force --deep $(CODESIGN_OPTIONS) $(CODESIGN_ENTITLEMENTS) --sign "$(CODESIGN_IDENTITY)" $(APP_BUNDLE); \
		echo "Built $(APP_BUNDLE) (signed with: $(CODESIGN_IDENTITY))"; \
	else \
		codesign --force --deep --sign - $(APP_BUNDLE); \
		echo "Built $(APP_BUNDLE) (ad-hoc signed — Developer ID cert missing from keychain; TCC grants will not persist across rebuilds)"; \
	fi

run: build
	open $(APP_BUNDLE)

install: build
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R $(APP_BUNDLE) "$(INSTALL_DIR)/"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

dist:
	@$(MAKE) build CODESIGN_OPTIONS="--options runtime --timestamp"
	@rm -rf "$(DIST_DIR)" "$(DMG_STAGING)"
	@mkdir -p "$(DIST_DIR)" "$(DMG_STAGING)"
	@cp -R "$(APP_BUNDLE)" "$(DIST_APP)"
	@echo "Built dist app: $(DIST_APP)"

# Two-stage notarization. The .app must carry its OWN stapled ticket: a staple
# on the DMG does NOT travel with Dousha.app once a user drags it to
# /Applications, so without this the extracted app fails Gatekeeper's offline
# check ("Apple cannot verify ..."). So we notarize + staple the app FIRST,
# then build the DMG around the already-stapled app, then notarize + staple
# the DMG itself (so the downloaded DMG also passes cleanly).
notarize: dist
	@ditto -c -k --keepParent "$(DIST_APP)" "$(DIST_DIR)/$(APP_NAME).zip"
	xcrun notarytool submit "$(DIST_DIR)/$(APP_NAME).zip" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DIST_APP)"
	@rm -f "$(DIST_DIR)/$(APP_NAME).zip"
	@cp -R "$(DIST_APP)" "$(DMG_STAGING)/$(APP_NAME).app"
	@ln -s /Applications "$(DMG_STAGING)/Applications"
	@hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_STAGING)" -ov -format UDZO "$(DIST_DMG)" >/dev/null
	@codesign --force --sign "$(DEVELOPER_ID_IDENTITY)" --timestamp "$(DIST_DMG)"
	xcrun notarytool submit "$(DIST_DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DIST_DMG)"
	@echo "Notarized and stapled both $(APP_NAME).app and $(DIST_DMG)"

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
	@$(MAKE) update-cask VERSION=$(VERSION)

# Bump the Homebrew cask in $(TAP_REPO) to $(VERSION) with the DMG's sha256.
# Clones the tap fresh (via gh auth), patches only the version/sha256 lines,
# and pushes. Idempotent: no-op if the cask already matches.
update-cask:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make update-cask VERSION=0.1.0"; exit 1; fi
	@if [ ! -f "$(DIST_DMG)" ]; then echo "ERROR: $(DIST_DMG) not found. Run 'make notarize' first."; exit 1; fi
	@sha=$$(shasum -a 256 "$(DIST_DMG)" | awk '{print $$1}'); \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	echo "Cloning $(TAP_REPO)..."; \
	gh repo clone "$(TAP_REPO)" "$$tmp" -- -q || exit 1; \
	sed -i '' -E "s/^  version \".*\"/  version \"$(VERSION)\"/" "$$tmp/$(CASK_PATH)"; \
	sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$$sha\"/" "$$tmp/$(CASK_PATH)"; \
	git -C "$$tmp" add "$(CASK_PATH)"; \
	if git -C "$$tmp" diff --cached --quiet; then \
		echo "Cask already at $(VERSION) / $$sha — nothing to push."; \
	else \
		git -C "$$tmp" commit -q -m "dousha $(VERSION)"; \
		git -C "$$tmp" push -q origin HEAD; \
		echo "Cask bumped to $(VERSION) ($$sha) and pushed to $(TAP_REPO)."; \
	fi

clean:
	rm -rf $(BUILD_DIR)

reset-perms:
	tccutil reset Microphone com.dousha.app || true
	tccutil reset SpeechRecognition com.dousha.app || true
	tccutil reset Accessibility com.dousha.app || true
