.PHONY: doctor build release run install preview lint format clean

doctor:
	./scripts/doctor.sh

build:
	./scripts/build.sh debug

release:
	./scripts/build.sh release

run: release
	./scripts/run.sh

install: release
	./scripts/install.sh

preview: build
	-killall MenuTools
	open -W -n build/MenuTools.app --args --render-preview "$(CURDIR)/build/preview-dashboard.png"
	open -W -n build/MenuTools.app --args --render-preview "$(CURDIR)/build/preview-settings.png" --settings

lint:
	xcrun swift-format lint --recursive Sources

format:
	xcrun swift-format format --in-place --recursive Sources

clean:
	swift package clean
