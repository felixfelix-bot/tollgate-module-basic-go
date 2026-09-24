.PHONY: portal-build reproducibility-test reproducibility-variance go-battery \
        regression regression-module regression-cloud-lab

# Canonical pre-PR Go gate across ALL 16 modules (src/ is a multi-module
# tree: `go ... ./...` from src/ alone covers only the root module).
# Same set the go-test CI lane runs: gofmt, vet, build, race tests.
go-battery:
	@bash scripts/go-battery.sh

# Regression lanes — ONE command for humans, agents and CI (the ngit lane
# .ngit/act/workflows/regression.yml runs exactly these). See REGRESSION.md for
# what each lane covers and RELEASE-GATE.md for what must be green before a feed
# bump.
#
#   make regression              module lane + cloud lab
#   make regression-module       stage an artifact from this checkout and run the
#                                happy-path suite against it, real browser included
#   make regression-cloud-lab    tests/cloud-lab docker-compose lab (needs docker)
#
# Exit status is the lanes': non-zero if a lane that ran failed. The cloud-lab
# lane SKIPs (loudly, with the reason) when docker/compose are unavailable; pass
# --require-docker to that lane to make a skip fatal.
regression:
	@bash scripts/regression-lane.sh --lane all

regression-module:
	@bash scripts/regression-lane.sh --lane module

regression-cloud-lab:
	@bash scripts/regression-lane.sh --lane cloud-lab

portal-build:
	@bash packaging/portal-build.sh

# Reproducibility check: build an artifact twice in independent clean roots
# and require byte-identical output. T = binaries | portal | ipk | ipk-upx | apk
# ARCH = x86_64 (default) | aarch64_cortex-a53 | arm_cortex-a7 | mips_24kc |
#        mipsel_24kc | aarch64_cortex-a72
reproducibility-test:
	@bash scripts/repro-test.sh "$(T)" "$(ARCH)"

reproducibility-test-default:
	@bash scripts/repro-test.sh binaries x86_64

# Variance check (reprotest): rebuild under hostile environment variations
# (umask, timezone, locales, file ordering) and require identical output —
# the complement to the clean-roots check above. Requires reprotest (pip).
reproducibility-variance:
	@bash scripts/repro-variance.sh "$(T)" "$(ARCH)"
