.PHONY: doctor build release run install preview lint format clean dmg

doctor:
	./scripts/doctor.sh

build:
	./scripts/build.sh debug

release:
	./scripts/build.sh release

dmg: release
	./scripts/package_dmg.sh

run: release
	./scripts/run.sh

install: release
	./scripts/install.sh

preview: build
	./scripts/preview.sh

lint:
	xcrun swift-format lint --recursive Sources

format:
	xcrun swift-format format --in-place --recursive Sources

clean:
	swift package clean
