SHELL := /usr/bin/env bash

# Par défaut, exécute tout le pipeline
.PHONY: run
run:
	bash scripts/run_all.sh

# Étapes individuelles (debug pas-à-pas)
.PHONY: step1 step2 step3 step4 step5 step6 step7 step8 step9 step10
step1:  ; bash scripts/01_config_dnf.sh
step2:  ; bash scripts/02_enable_dark_mode.sh
step3:  ; bash scripts/03_remove_bloat.sh
step4:  ; bash scripts/04_repos_and_codecs.sh
step5:  ; bash scripts/05_gpu_drivers.sh
step6:  ; bash scripts/06_display_manager.sh
step7:  ; bash scripts/07_install_dots.sh
step8:  ; bash scripts/08_install_apps.sh
step9:  ; bash scripts/09_boot_optimize.sh
step10: ; bash scripts/10_ai_stack.sh

# Raccourcis utiles
.PHONY: dm-ly dm-greetd dm-gdm
dm-ly:
	DM=ly bash scripts/06_display_manager.sh
dm-greetd:
	DM=greetd bash scripts/06_display_manager.sh
dm-gdm:
	DM=gdm bash scripts/06_display_manager.sh

.PHONY: ai
ai:
	bash scripts/10_ai_stack.sh

.PHONY: boot-optimize
boot-optimize:
	bash scripts/09_boot_optimize.sh

.PHONY: dots
dots:
	bash scripts/07_install_dots.sh
