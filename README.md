# Re-create the README.md file as a downloadable file
readme_content = """# Fedora Lite Autoconfig

A reproducible setup script for **Fedora Workstation** aimed at creating a **lightweight yet powerful system**:
- Keep GNOME session available, but use **Hyprland** as the main compositor.
- Optimized for **development**, **gaming**, and **AI (CUDA/ROCm)**.
- Includes support for **AMD** and **NVIDIA** GPUs.
- Publicly shareable: all configs, scripts, and lists are version-controlled.

---

## Features

- **System tuning**
  - DNF optimizations (`/etc/dnf/dnf.conf`).
  - Fast boot (< 6s target).
  - Optional Plymouth removal.

- **User experience**
  - Dark mode enabled by default.
  - Display manager switch (Ly, greetd, or GDM).
  - Dotfiles (`caelestia-fedora`) auto-installed with Fish + Foot terminal.

- **Package management**
  - Removal of unneeded GNOME “bloat” apps.
  - Installation of favorite apps via:
    - **RPMs** (`lists/rpm-packages.txt`)
    - **Flatpaks** (`lists/flatpaks.txt`)
    - **AppImages** (`lists/appimages.txt`)

- **GPU & AI support**
  - Auto-detect AMD / NVIDIA / Intel.
  - Drivers + Vulkan/OpenGL setup.
  - Optional **CUDA** (NVIDIA) or **ROCm** (AMD).
  - OpenCL ICD + `clinfo` installed by default.

---

## Project Structure

scripts/
  00_helpers.sh         # Common helpers (as_root, as_user, etc.)
  00_system_update.sh   # System upgrade (optional, run first)
  01_config_dnf.sh
  02_enable_dark_mode.sh
  03_remove_bloat.sh
  04_repos_and_codecs.sh
  05_gpu_drivers.sh
  06_display_manager.sh
  07_install_dots.sh
  08_install_apps.sh
  09_boot_optimize.sh
  10_ai_stack.sh
  run_all.sh            # Run the full pipeline

lists/
  remove-packages.txt   # GNOME bloat to remove
  rpm-packages.txt      # RPM packages to install
  flatpaks.txt          # Flatpaks to install
  appimages.txt         # AppImages to install
  coprs.txt             # COPR repos to enable
  services-disable.txt  # Systemd services to disable

config/
  ly/config.ini         # Example config for Ly
  greetd/config.toml    # Example config for greetd

---

## Quick Start

### 1. Clone this repo
git clone https://github.com/EnceladusII/fedora-lite.git ~/.local/share/fedora-lite
cd ~/.local/share/fedora-lite

### 2. Prepare `.env`
cp .env.example .env
nano .env

Key options:
- GPU=auto|amd|nvidia|intel
- DM=ly|greetd|gdm
- DEFAULT_SHELL=fish|bash
- REMOVE_PLYMOUTH=1 to remove Plymouth for faster boot.

### 3. Run everything
make run

This will:
1. Update system (dnf upgrade --refresh).
2. Apply configs (DNF, dark mode).
3. Remove bloat.
4. Enable RPMFusion, Flathub, COPRs.
5. Install GPU drivers.
6. Install dotfiles (Fish + Foot + sass).
7. Switch Display Manager (Ly by default).
8. Install your apps (RPM / Flatpak / AppImage).
9. Optimize boot (services, GRUB, Plymouth).
10. Install AI stack (CUDA/ROCm/OpenCL).

---

## Debugging / Running steps manually

You can run steps individually:
make step1   # configure DNF
make step3   # remove bloat
make step8   # install apps

Or directly:
bash scripts/03_remove_bloat.sh

---

## Customization

- Edit lists/remove-packages.txt → remove unwanted GNOME apps.
- Edit lists/rpm-packages.txt → add RPM packages.
- Edit lists/flatpaks.txt → add Flatpaks.
- Edit lists/appimages.txt → add AppImages (downloaded to ~/Applications).
- Edit lists/services-disable.txt → disable unwanted services.
- Edit lists/coprs.txt → enable extra COPR repos.

---

## AI / GPU Notes

- NVIDIA: CUDA via official NVIDIA repo or RPMFusion.
- AMD: ROCm best-effort (upstream or COPR).
- Intel: base OpenCL only; oneAPI not covered here.
- OpenCL loader + clinfo installed by default.

---

## License

This project is GNU licensed.
Feel free to fork, modify, and adapt to your workflow.
