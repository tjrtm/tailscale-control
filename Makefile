.PHONY: build test dmg clean verify

build:
	./scripts/build.sh

test: build
	"build/Tailscale Control.app/Contents/MacOS/Tailscale Control" --self-test
	"build/Tailscale Control.app/Contents/MacOS/Tailscale Control" --close-self-test

verify: test
	plutil -lint "build/Tailscale Control.app/Contents/Info.plist"
	codesign --verify --deep --strict --verbose=2 "build/Tailscale Control.app"

dmg: verify
	./scripts/package-dmg.sh

clean:
	rm -rf build dist
