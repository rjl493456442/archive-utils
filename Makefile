.PHONY: check

check:
	bash -n run.sh monitor.sh
	docker compose -p geth-archive config -q
