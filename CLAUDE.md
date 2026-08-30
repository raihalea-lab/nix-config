# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Nix Flake-based dotfiles repository that manages system configuration for both WSL (Windows Subsystem for Linux) and macOS using Home Manager and nix-darwin.

## Commands

### Apply configuration changes

```bash
# Automatic (uses shell alias that detects OS)
hm-apply

# Manual - macOS (nix-darwin)
sudo nix run nix-darwin -- switch --flake ~/.config/home-manager#raiha

# Manual - WSL (home-manager standalone)
home-manager switch --flake ~/.config/home-manager#wsl
```

### Update and apply

```bash
hm-update  # Update flake inputs and apply
```

### Cleanup

```bash
hm-clean  # runs nix-collect-garbage -d
```

## Architecture

```
~/.config/home-manager/
├── flake.nix          # Entry point (WSL: homeConfigurations.wsl, macOS: darwinConfigurations.raiha)
├── home.nix           # Basic home-manager settings (username, homeDirectory)
├── darwin.nix         # macOS system settings (Touch ID, Homebrew casks, Dock/Finder)
└── modules/
    ├── common/        # Shared across all platforms
    │   ├── default.nix    # Common packages (git, gh, devenv, awscli2, uv, nodejs, etc.)
    │   ├── shell.nix      # zsh, bash, starship, direnv, common aliases
    │   └── git.nix        # Git config with git-secrets
    ├── darwin/        # macOS only
    │   ├── default.nix
    │   ├── packages.nix   # docker, colima, docker-buildx (nix packages)
    │   ├── homebrew.nix   # homebrew casks (docker, ghostty, zoom, claude-code)
    │   └── aliases.nix    # colima-start, colima-stop, colima-status
    └── wsl/           # WSL only
        ├── default.nix
        ├── packages.nix   # WSL-specific packages
        └── aliases.nix    # open=explorer.exe
```

## Key Patterns

- OS detection uses `pkgs.stdenv.hostPlatform.isDarwin`
- Platform-specific code goes in `modules/darwin/` or `modules/wsl/`
- `shellAliases` are merged from common and platform-specific modules
- flake.nix imports different module combinations per platform
- `modules/darwin/homebrew.nix` is loaded as a nix-darwin module (not home-manager)
