APP_NAME         := MojoPulse
BUILD_DIR        := .build/release
APP_BUNDLE       := $(APP_NAME).app
DIST_DIR         := dist
VERSION          := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
BUILD_NUMBER_FILE := .build-number
DMG_NAME         := $(APP_NAME)-$(VERSION).dmg

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
	@# Auto-increment CFBundleVersion on every build. Stored in a gitignored
	@# counter file so the source Info.plist (and working tree) stay clean
	@# — we only patch the copy inside the bundle. CFBundleShortVersionString
	@# (the marketing version, e.g. 0.1.0) is still bumped by hand.
	@BUILD_NUM=$$(( $$(cat $(BUILD_NUMBER_FILE) 2>/dev/null || echo 0) + 1 )); \
		echo $$BUILD_NUM > $(BUILD_NUMBER_FILE); \
		/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$BUILD_NUM" $(APP_BUNDLE)/Contents/Info.plist; \
		echo "Build $(VERSION) ($$BUILD_NUM)"
	@codesign --force --deep --sign - $(APP_BUNDLE)
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
		DMG_PATH="$(DIST_DIR)/$(APP_NAME)-$(VERSION)-build$$BUILD_NUM.dmg"; \
		rm -f "$$DMG_PATH"; \
		hdiutil create \
			-volname "$(APP_NAME) $(VERSION)" \
			-srcfolder $(DIST_DIR)/staging \
			-ov -format UDZO \
			"$$DMG_PATH" >/dev/null; \
		rm -rf $(DIST_DIR)/staging; \
		echo "Built $$DMG_PATH ($$(du -h "$$DMG_PATH" | cut -f1))"

print-version:
	@BUILD_NUM=$$(cat $(BUILD_NUMBER_FILE) 2>/dev/null || echo 0); \
		echo "$(VERSION) (build $$BUILD_NUM)"

clean:
	@rm -rf .build $(APP_BUNDLE) $(DIST_DIR)
