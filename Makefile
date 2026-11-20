# The Command Line Tools ship the Swift Testing framework outside the default search path.
CLT := /Library/Developer/CommandLineTools/Library/Developer
TEST_FLAGS := $(if $(wildcard $(CLT)/Frameworks/Testing.framework),-Xswiftc -F -Xswiftc $(CLT)/Frameworks -Xlinker -F -Xlinker $(CLT)/Frameworks -Xlinker -rpath -Xlinker $(CLT)/Frameworks -Xlinker -rpath -Xlinker $(CLT)/usr/lib,)

.PHONY: app install run test clean signing claude-command

app:
	./scripts/build-app.sh

install: app
	rm -rf /Applications/Legato.app
	cp -R build/Legato.app /Applications/Legato.app

run: app
	open build/Legato.app

signing:
	./scripts/dev-signing.sh

# Installs the /legato-vocabulary command for Claude Code.
claude-command:
	mkdir -p $(HOME)/.claude/commands
	cp integrations/claude-code/legato-vocabulary.md $(HOME)/.claude/commands/legato-vocabulary.md

test:
	swift test $(TEST_FLAGS)

clean:
	rm -rf .build build
