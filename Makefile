APP_NAME         := MojoPulse
BUILD_DIR        := .build/release
APP_BUNDLE       := $(APP_NAME).app
DIST_DIR         := dist
# Marketing version base (MAJOR.MINOR). The patch component is filled in
# automatically from the auto-incrementing build counter, so every bundle
# build produces a fresh, monotonically increasing rev (1.0.10, 1.0.11, …).
# Bump this by hand only for a real minor/major release.
MARKETING_VERSION := 1.0
BUILD_NUMBER_FILE := .build-number
# Code-signing identity. "-" = ad-hoc (current). Override with your Developer
# ID once you have the cert, e.g.:
#   make app SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
SIGN_IDENTITY    := -

.PHONY: build debug run app install dmg clean print-version

build:
	swift build -c release

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
	@# Auto-increment the build counter, then stamp BOTH the marketing version
	@# (MARKETING_VERSION.<build>) and CFBundleVersion into the bundle's copy of
	@# Info.plist on every build. The counter lives in a gitignored file and we
	@# only patch the copy inside the bundle, so the source Info.plist and the
	@# working tree stay clean — but every build gets a unique, rising rev.
	@BUILD_NUM=$$(( $$(cat $(BUILD_NUMBER_FILE) 2>/dev/null || echo 0) + 1 )); \
		echo $$BUILD_NUM > $(BUILD_NUMBER_FILE); \
		FULL_VERSION="$(MARKETING_VERSION).$$BUILD_NUM"; \
		/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $$FULL_VERSION" $(APP_BUNDLE)/Contents/Info.plist; \
		/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$BUILD_NUM" $(APP_BUNDLE)/Contents/Info.plist; \
		echo "Built $(APP_NAME) $$FULL_VERSION (build $$BUILD_NUM)"
	@# Embed Sparkle.framework so the app can update itself, then code-sign
	@# inside-out (nested XPC/helpers first, then the framework, then the app).
	@# Ad-hoc ("-") for now; once you have a Developer ID cert, set
	@# SIGN_IDENTITY to it and add `-o runtime` for notarization.
	@mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	@rm -rf $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	@cp -R $(BUILD_DIR)/Sparkle.framework $(APP_BUNDLE)/Contents/Frameworks/
	@SP=$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework/Versions/B; \
		codesign -f -s "$(SIGN_IDENTITY)" "$$SP/XPCServices/Installer.xpc"; \
		codesign -f -s "$(SIGN_IDENTITY)" "$$SP/XPCServices/Downloader.xpc"; \
		codesign -f -s "$(SIGN_IDENTITY)" "$$SP/Autoupdate"; \
		codesign -f -s "$(SIGN_IDENTITY)" "$$SP/Updater.app"; \
		codesign -f -s "$(SIGN_IDENTITY)" "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"; \
		codesign -f -s "$(SIGN_IDENTITY)" "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

install: app
	@rm -rf /Applications/$(APP_BUNDLE)
	@cp -R $(APP_BUNDLE) /Applications/
	@echo "Installed to /Applications/$(APP_BUNDLE)"

# Build a compressed, distributable DMG containing the ad-hoc-signed .app
# and an Applications symlink (the familiar drag-to-Applications affordance).
# Because we're ad-hoc signing, users who download the DMG will need to
# right-click the .app and choose Open the first time so macOS Gatekeeper
# lets it past the "developer cannot be verified" check, or run
# `xattr -d com.apple.quarantine /Applications/$(APP_BUNDLE)` after install.
dmg: app
	@mkdir -p $(DIST_DIR)
	@rm -rf $(DIST_DIR)/staging
	@mkdir -p $(DIST_DIR)/staging
	@cp -R $(APP_BUNDLE) $(DIST_DIR)/staging/
	@ln -sf /Applications $(DIST_DIR)/staging/Applications
	@BUILD_NUM=$$(cat $(BUILD_NUMBER_FILE)); \
		FULL_VERSION="$(MARKETING_VERSION).$$BUILD_NUM"; \
		DMG_PATH="$(DIST_DIR)/$(APP_NAME)-$$FULL_VERSION.dmg"; \
		rm -f "$$DMG_PATH"; \
		hdiutil create \
			-volname "$(APP_NAME) $$FULL_VERSION" \
			-srcfolder $(DIST_DIR)/staging \
			-ov -format UDZO \
			"$$DMG_PATH" >/dev/null; \
		rm -rf $(DIST_DIR)/staging; \
		echo "Built $$DMG_PATH ($$(du -h "$$DMG_PATH" | cut -f1))"

print-version:
	@BUILD_NUM=$$(cat $(BUILD_NUMBER_FILE) 2>/dev/null || echo 0); \
		echo "$(MARKETING_VERSION).$$BUILD_NUM (build $$BUILD_NUM)"

clean:
	@rm -rf .build $(APP_BUNDLE) $(DIST_DIR)
