APP_NAME         := MojoPulse
# We ship a universal (arm64 + x86_64) binary. SwiftPM emits each slice into its
# own triple-named dir; the `build` target lipos them into BUILD_DIR, and every
# downstream target (app/install/dmg/notarize/release) consumes BUILD_DIR as
# before. The single-command `swift build --arch arm64 --arch x86_64` form needs
# full Xcode's xcbuild, so we build each arch natively and fuse with lipo — that
# works on a Command Line Tools-only box too.
ARM64_DIR        := .build/arm64-apple-macosx/release
X86_64_DIR       := .build/x86_64-apple-macosx/release
BUILD_DIR        := .build/universal
APP_BUNDLE       := $(APP_NAME).app
DIST_DIR         := dist
# Marketing version shown to users (CFBundleShortVersionString). Bump by hand
# per release. CFBundleVersion is the auto-incrementing build counter below —
# that's what Sparkle compares to decide "is there a newer build?", so the
# display version can stay fixed across builds without breaking auto-update.
MARKETING_VERSION := 1.16.2
BUILD_NUMBER_FILE := .build-number
# Code-signing identity. The Developer ID Application cert for 311 Labs, LLC.
# (Team 7UURCYAQ8Y) is the default so `make app/install/release` sign for real.
# Override with SIGN_IDENTITY="-" to fall back to ad-hoc (e.g. a machine without
# the cert); the hardened-runtime flags below auto-disable for ad-hoc.
SIGN_IDENTITY    := Developer ID Application: 311 Labs, LLC. (7UURCYAQ8Y)
# Notarization credential. A keychain profile (`notarytool store-credentials`)
# works, but the login keychain relocks during the multi-minute `--wait` and the
# submit then fails with "No Keychain password item found", killing the release
# mid-flight. So we pass the App Store Connect API key (.p8) directly — no
# keychain involved. The .p8 is the only secret and stays out of the repo in
# ~/mojopulse-signing; the key-id and issuer are non-secret identifiers.
NOTARY_PROFILE   := mojopulse-notary
NOTARY_KEY       := $(HOME)/mojopulse-signing/AuthKey_D56868A4PH.p8
NOTARY_KEY_ID    := D56868A4PH
NOTARY_ISSUER    := 69a6de7e-f152-47e3-e053-5b8c7c11a4d1
NOTARY_AUTH      := --key $(NOTARY_KEY) --key-id $(NOTARY_KEY_ID) --issuer $(NOTARY_ISSUER)

# Hardened runtime + a secure timestamp are required for notarization, but only
# work with a real Developer ID identity (ad-hoc "-" can't timestamp). Toggle
# them off automatically when signing ad-hoc.
ifeq ($(SIGN_IDENTITY),-)
CODESIGN_OPTS    :=
else
CODESIGN_OPTS    := --options runtime --timestamp
endif

.PHONY: build debug run app install dmg notarize release clean print-version

build:
	swift build -c release --arch x86_64
	swift build -c release --arch arm64
	@mkdir -p $(BUILD_DIR)
	@# Fuse the two thin executables into one universal Mach-O.
	@lipo -create $(ARM64_DIR)/$(APP_NAME) $(X86_64_DIR)/$(APP_NAME) -output $(BUILD_DIR)/$(APP_NAME)
	@# Sparkle ships a prebuilt universal binary artifact, so its framework is
	@# already arm64+x86_64 in either per-arch dir — copy it through unchanged.
	@rm -rf $(BUILD_DIR)/Sparkle.framework
	@cp -R $(ARM64_DIR)/Sparkle.framework $(BUILD_DIR)/Sparkle.framework
	@echo "Universal binary: $$(lipo -info $(BUILD_DIR)/$(APP_NAME) | sed 's/.*are: //')"

debug:
	swift build

run:
	swift run -c release

app: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	@cp Info.plist $(APP_BUNDLE)/Contents/
	@cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	@cp Resources/PulseMark.png $(APP_BUNDLE)/Contents/Resources/
	@cp Resources/WorldOutline.json $(APP_BUNDLE)/Contents/Resources/
	@cp Resources/oui.csv $(APP_BUNDLE)/Contents/Resources/
	@# Auto-increment the build counter (gitignored file) and stamp the bundle's
	@# COPY of Info.plist: CFBundleShortVersionString = the marketing version,
	@# CFBundleVersion = the rising build number Sparkle compares. We patch only
	@# the bundle copy, so the source Info.plist and working tree stay clean.
	@BUILD_NUM=$$(( $$(cat $(BUILD_NUMBER_FILE) 2>/dev/null || echo 0) + 1 )); \
		echo $$BUILD_NUM > $(BUILD_NUMBER_FILE); \
		/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(MARKETING_VERSION)" $(APP_BUNDLE)/Contents/Info.plist; \
		/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$BUILD_NUM" $(APP_BUNDLE)/Contents/Info.plist; \
		echo "Built $(APP_NAME) $(MARKETING_VERSION) (build $$BUILD_NUM)"
	@# Inject the mojoverify geo-lookup API key into the bundle's Info.plist
	@# (NOT the source plist) from the dev secrets file, so the key is never
	@# committed. Absent file = geo lookup simply stays unavailable in the build.
	@if [ -f "$(HOME)/mojopulse-signing/mojoverify-apikey.txt" ]; then \
		KEY=$$(tr -d ' \n\r' < "$(HOME)/mojopulse-signing/mojoverify-apikey.txt"); \
		/usr/libexec/PlistBuddy -c "Add :MVGeoAPIKey string $$KEY" $(APP_BUNDLE)/Contents/Info.plist 2>/dev/null \
			|| /usr/libexec/PlistBuddy -c "Set :MVGeoAPIKey $$KEY" $(APP_BUNDLE)/Contents/Info.plist; \
		echo "Injected mojoverify geo API key into bundle"; \
	else echo "No mojoverify API key file — geo lookup disabled in this build"; fi
	@# Embed Sparkle.framework so the app can update itself, then code-sign
	@# inside-out (nested XPC/helpers first, then the framework, then the app),
	@# never with --deep. With a Developer ID identity CODESIGN_OPTS adds the
	@# hardened runtime + secure timestamp that notarization requires. Sparkle's
	@# Downloader.xpc ships sandbox/network entitlements that must be preserved.
	@mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	@rm -rf $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	@cp -R $(BUILD_DIR)/Sparkle.framework $(APP_BUNDLE)/Contents/Frameworks/
	@SP=$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework/Versions/B; \
		codesign -f $(CODESIGN_OPTS) --preserve-metadata=entitlements -s "$(SIGN_IDENTITY)" "$$SP/XPCServices/Downloader.xpc"; \
		codesign -f $(CODESIGN_OPTS) -s "$(SIGN_IDENTITY)" "$$SP/XPCServices/Installer.xpc"; \
		codesign -f $(CODESIGN_OPTS) -s "$(SIGN_IDENTITY)" "$$SP/Autoupdate"; \
		codesign -f $(CODESIGN_OPTS) -s "$(SIGN_IDENTITY)" "$$SP/Updater.app"; \
		codesign -f $(CODESIGN_OPTS) -s "$(SIGN_IDENTITY)" "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"; \
		codesign -f $(CODESIGN_OPTS) -s "$(SIGN_IDENTITY)" "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"
	@codesign --verify --strict --verbose=2 "$(APP_BUNDLE)" 2>&1 | tail -1 || true

install: app
	@rm -rf /Applications/$(APP_BUNDLE)
	@cp -R $(APP_BUNDLE) /Applications/
	@echo "Installed to /Applications/$(APP_BUNDLE)"

# Build a compressed, distributable DMG (signed .app + an Applications symlink
# for drag-to-install). For a notarized public release use `make release`
# instead — this bare `dmg` target is just a quick local build.
dmg: app
	@mkdir -p $(DIST_DIR)
	@rm -rf $(DIST_DIR)/staging
	@mkdir -p $(DIST_DIR)/staging
	@cp -R $(APP_BUNDLE) $(DIST_DIR)/staging/
	@ln -sf /Applications $(DIST_DIR)/staging/Applications
	@FULL_VERSION="$(MARKETING_VERSION)"; \
		DMG_PATH="$(DIST_DIR)/$(APP_NAME)-$$FULL_VERSION.dmg"; \
		rm -f "$$DMG_PATH"; \
		hdiutil create \
			-volname "$(APP_NAME) $$FULL_VERSION" \
			-srcfolder $(DIST_DIR)/staging \
			-ov -format UDZO \
			"$$DMG_PATH" >/dev/null; \
		rm -rf $(DIST_DIR)/staging; \
		echo "Built $$DMG_PATH ($$(du -h "$$DMG_PATH" | cut -f1))"

# Notarize the signed app: zip it, submit to Apple's notary service, wait for
# the result, then staple the ticket onto the .app so it validates even offline.
# Requires a Developer ID SIGN_IDENTITY and the NOTARY_PROFILE credential.
notarize: app
	@mkdir -p $(DIST_DIR)
	@ditto -c -k --keepParent $(APP_BUNDLE) $(DIST_DIR)/$(APP_NAME)-notarize.zip
	@echo "Submitting to Apple notary service (can take a few minutes)…"
	xcrun notarytool submit $(DIST_DIR)/$(APP_NAME)-notarize.zip \
		$(NOTARY_AUTH) --wait
	@xcrun stapler staple $(APP_BUNDLE)
	@rm -f $(DIST_DIR)/$(APP_NAME)-notarize.zip
	@echo "Notarized + stapled $(APP_BUNDLE)"
	@spctl -a -vvv --type execute $(APP_BUNDLE) 2>&1 || true

# Full release: build → sign → notarize+staple the app → package the STAPLED
# app into a DMG → notarize+staple the DMG → print the SHA256 (for the Homebrew
# cask) and version. This is the distributable artifact.
#
# To actually SHIP a release (version bump + tag + this target + signed
# appcast + GitHub release + Homebrew tap bump, all in one call), don't run
# this directly — use `scripts/release.sh` instead. See its header comment
# or `scripts/release.sh --help`.
release: notarize
	@mkdir -p $(DIST_DIR)/staging
	@rm -rf $(DIST_DIR)/staging
	@mkdir -p $(DIST_DIR)/staging
	@cp -R $(APP_BUNDLE) $(DIST_DIR)/staging/
	@ln -sf /Applications $(DIST_DIR)/staging/Applications
	@FULL_VERSION="$(MARKETING_VERSION)"; \
		DMG_PATH="$(DIST_DIR)/$(APP_NAME)-$$FULL_VERSION.dmg"; \
		rm -f "$$DMG_PATH"; \
		hdiutil create -volname "$(APP_NAME) $$FULL_VERSION" \
			-srcfolder $(DIST_DIR)/staging -ov -format UDZO "$$DMG_PATH" >/dev/null; \
		rm -rf $(DIST_DIR)/staging; \
		echo "Submitting DMG to notary service…"; \
		xcrun notarytool submit "$$DMG_PATH" $(NOTARY_AUTH) --wait; \
		xcrun stapler staple "$$DMG_PATH"; \
		SHA=$$(shasum -a 256 "$$DMG_PATH" | cut -d' ' -f1); \
		echo ""; \
		echo "=== Release ready ==="; \
		echo "DMG:     $$DMG_PATH"; \
		echo "Version: $$FULL_VERSION"; \
		echo "SHA256:  $$SHA"

print-version:
	@BUILD_NUM=$$(cat $(BUILD_NUMBER_FILE) 2>/dev/null || echo 0); \
		echo "$(MARKETING_VERSION) (build $$BUILD_NUM)"

clean:
	@rm -rf .build $(APP_BUNDLE) $(DIST_DIR)
