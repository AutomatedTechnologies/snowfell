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
	Snowfell/IncidentModels.m

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
	Snowfell/IncidentModels.h

# startup-sound.wav: byte-identical to the SDS-10 library master,
# SHA-256 07a113244c6b432b22954a089ce519bd239311b14a48f26ae85214ed8c25b09a.
# registry.db + snapshot-manifest.json: registry snapshot v7-0038,
# SHA-256 f5e1cb8741b1908140796f7fab5f041baf5fdd87281c003105888a4e6a186916
# (registry content head e695fcf9116a6123b0503be853cf56a8c5223d18;
# refreshed at SF-T8 — the sf_* domain is unchanged since changes/0031
# (the §12 incident domain included); SnapshotSync can advance it
# further at runtime).
RESOURCES = \
	Snowfell/Resources/startup-sound.wav \
	Snowfell/Resources/registry.db \
	Snowfell/Resources/snapshot-manifest.json \
	Snowfell/Resources/LICENSE-ACADEMY.txt \
	Snowfell/Resources/NOTICE.txt

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
