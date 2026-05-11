install:
	swift build -c release
	install .build/release/ikit ~/.local/bin/ikit

test: test_agent_cli test_health
	@echo "Running all tests..."

test_agent_cli:
	swift build
	./test_agent_cli.sh

test_health:
	./test_e2e_health.sh

test_e2e:
	./test_e2e_final.sh
