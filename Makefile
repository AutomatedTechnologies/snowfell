# Snowfell — file manifest + build rules (SF-T2 scaffold).
#
# This Makefile is the scaffold's bill of materials: SOURCES and RESOURCES
# are the complete file list. build.sh is a thin wrapper over these targets.
#
#   make check   syntax-check every .m against the MacOSX10.13 SDK
#                (Linux VM recipe per estate TOOLS.md; no link, no run)
#   make app     assemble Snowfell.app (macOS only — system clang + AppKit)

SOURCES = \
	Snowfell/main.m \
	Snowfell/AppDelegate.m \
	Snowfell/AcademyWelcomeController.m \
	Snowfell/AcademyAppIconView.m \
	Snowfell/PortfolioViewController.m \
	Snowfell/BoardViewController.m \
	Snowfell/ItemDetailViewController.m \
	Snowfell/WriteBackQueueViewController.m \
	Snowfell/OrchestrationViewController.m \
	Snowfell/RoadmapViewController.m \
	Snowfell/CommandPaletteViewController.m \
	Snowfell/IncidentsViewController.m \
	Snowfell/StorageViewController.m \
	Snowfell/NavigationBar.m \
	Snowfell/UpdatesViewController.m \
	Snowfell/CloudServiceClient.m \
	Snowfell/CloudModels.m \
	Snowfell/SnapshotStore.m \
	Snowfell/WriteBackQueue.m \
	Snowfell/DispatchStore.m \
	Snowfell/GitHubProjectsClient.m \
	Snowfell/BoardSummary.m \
	Snowfell/BoardItem.m \
	Snowfell/ItemFieldValue.m \
	Snowfell/ElementHandler.m \
	Snowfell/StatusField.m \
	Snowfell/SFAction.m \
	Snowfell/DeployTarget.m \
	Snowfell/SnapshotSync.m \
	Snowfell/DatedItem.m \
	Snowfell/DraftRow.m \
	Snowfell/PaletteResult.m \
	Snowfell/IncidentModels.m \
	Snowfell/AcademyTheme.m

HEADERS = \
	Snowfell/AppDelegate.h \
	Snowfell/AcademyWelcomeController.h \
	Snowfell/AcademyAppIconView.h \
	Snowfell/PortfolioViewController.h \
	Snowfell/BoardViewController.h \
	Snowfell/ItemDetailViewController.h \
	Snowfell/WriteBackQueueViewController.h \
	Snowfell/OrchestrationViewController.h \
	Snowfell/RoadmapViewController.h \
	Snowfell/CommandPaletteViewController.h \
	Snowfell/IncidentsViewController.h \
	Snowfell/StorageViewController.h \
	Snowfell/NavigationBar.h \
	Snowfell/UpdatesViewController.h \
	Snowfell/CloudServiceClient.h \
	Snowfell/CloudModels.h \
	Snowfell/SnapshotStore.h \
	Snowfell/WriteBackQueue.h \
	Snowfell/DispatchStore.h \
	Snowfell/GitHubProjectsClient.h \
	Snowfell/BoardSummary.h \
	Snowfell/BoardItem.h \
	Snowfell/ItemFieldValue.h \
	Snowfell/ElementHandler.h \
	Snowfell/StatusField.h \
	Snowfell/SFAction.h \
	Snowfell/DeployTarget.h \
	Snowfell/SnapshotSync.h \
	Snowfell/DatedItem.h \
	Snowfell/DraftRow.h \
	Snowfell/PaletteResult.h \
	Snowfell/IncidentModels.h \
	Snowfell/AcademyTheme.h

# startup-sound.wav: byte-identical to the SDS-10 library master,
# SHA-256 07a113244c6b432b22954a089ce519bd239311b14a48f26ae85214ed8c25b09a.
# registry.db + snapshot-manifest.json: registry snapshot v9-0049,
# SHA-256 4bd7ec4e4499eeaaefef8c1b3d57fc78591c97f90f5768720af7f07e625d2328
# (schema 9 — includes the §12 incident domain and the SF-T12 sf_cloud_*
# catalog projection; refreshed at the snowfell-test-4 repack from the
# served snapshot of record; SnapshotSync can advance it further at
# runtime).
RESOURCES = \
	Snowfell/Resources/startup-sound.wav \
	Snowfell/Resources/registry.db \
	Snowfell/Resources/snapshot-manifest.json \
	Snowfell/Resources/LICENSE-ACADEMY.txt \
	Snowfell/Resources/NOTICE.txt

# SnowfellStorageService (SF-T12, cloud design record 03 §2.1): the
# Storage lens's companion helper is built by StorageService/Makefile
# from the portable-C sources in StorageService/ and copied into the
# bundle (Contents/MacOS/, beside the app executable, where the lens's
# pathForAuxiliaryExecutable: finds it) at PACKAGING time. It is
# deliberately NOT part of the `app` target's compile line above — the
# helper joins at packaging, which is SF-T8's line; source builds of
# the app alone therefore lack it, and the V12 lens states that in its
# service line instead of faking a Start.

SDK ?= $(HOME)/workspace/tools/sdks/MacOSX10.13.sdk
CLANG ?= clang
CHECKFLAGS = -target x86_64-apple-darwin17 -isysroot $(SDK) \
	-fobjc-runtime=macosx-10.13 -fobjc-arc -fsyntax-only -ISnowfell

.PHONY: check app
check:
	@for src in $(SOURCES); do \
		echo "== $$src"; \
		$(CLANG) $(CHECKFLAGS) $$src || exit 1; \
	done
	@echo "ALL SYNTAX OK"

app:
	if [ "$$(uname)" != "Darwin" ]; then \
		echo "make app requires macOS (system clang + AppKit)" >&2; exit 1; \
	fi
	rm -rf Snowfell.app
	mkdir -p Snowfell.app/Contents/MacOS Snowfell.app/Contents/Resources
	$(CLANG) -target x86_64-apple-macos10.13 -fobjc-arc -ISnowfell \
		-framework AppKit -framework Foundation -framework Security -lsqlite3 \
		-o Snowfell.app/Contents/MacOS/Snowfell $(SOURCES)
	cp Snowfell/Info.plist Snowfell.app/Contents/Info.plist
	cp $(RESOURCES) Snowfell.app/Contents/Resources/
	@echo "Snowfell.app assembled — launch with: open Snowfell.app"
