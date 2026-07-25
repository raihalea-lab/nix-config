{ config, pkgs, ... }:

let
  isDarwin = pkgs.stdenv.isDarwin;
  username = "raiha";
  homePrefix = if isDarwin then "/Users" else "/home";
  configDir = "${homePrefix}/${username}/.config/home-manager";
  applyCommand = if isDarwin
    then "sudo nix run nix-darwin -- switch --flake ${configDir}#raiha"
    else "home-manager switch --flake ${configDir}#wsl";
in
{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    shellAliases = {
      ll = "ls -la";
      hm-apply = applyCommand;
      hm-update = "nix flake update --flake ${configDir} && ${applyCommand}";
      hm-clean = "nix-collect-garbage -d";
    };

    initContent = ''
      export EDITOR=vim
      export PATH="$HOME/.local/bin:$PATH"

      # Vite+ (vp) CLI
      if [ -d "$HOME/.vite-plus/bin" ]; then
        export PATH="$HOME/.vite-plus/bin:$PATH"
      fi

      # Homebrewの設定 (Mac用)
      if [ -f "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      elif [ -f "/usr/local/bin/brew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
      fi

      # cargo (Rust)
      if [ -f "$HOME/.cargo/env" ]; then
        . "$HOME/.cargo/env"
      fi

      # ghq + fzf
      function ghq-fzf() {
        local src=$(ghq list | fzf --preview "bat --color=always --style=header,grid --line-range :80 $(ghq root)/{}/README.*")
        if [ -n "$src" ]; then
          BUFFER="cd $(ghq root)/$src"
          zle accept-line
        fi
        zle -R -c
      }
      zle -N ghq-fzf
      bindkey '^]' ghq-fzf
    '';
  };

  programs.bash = {
    enable = true;
    initExtra = ''
      if [ -x "$HOME/.nix-profile/bin/zsh" ]; then
        exec "$HOME/.nix-profile/bin/zsh"
      fi
    '';
  };

  programs.starship = {
    enable = true;
    enableZshIntegration = true;

    settings = {
      format = "$hostname$directory$git_branch$git_status$nix_shell$package$fill$cmd_duration$line_break$character";
      right_format = "$time";
      add_newline = true;

      # SSH接続時のみ表示（ssh_only はデフォルト true）
      hostname = {
        format = "[$hostname]($style) ";
        style = "bold yellow";
      };

      directory = {
        truncation_length = 3;
        style = "bold blue";
      };

      git_branch = {
        symbol = " ";
        style = "bg:none fg:purple";
      };
      git_status = {
        style = "bg:none fg:red";
        format = "[$all_status$ahead_behind]($style) ";
      };

      nix_shell = {
        disabled = false;
        symbol = " ";
        format = "via [$symbol$state]($style) ";
      };

      package = {
        disabled = true;
      };
      python = {
        symbol = " ";
        format = "via [$symbol($version )]($style)";
      };
      nodejs = {
        symbol = " ";
        format = "via [$symbol($version )]($style)";
      };

      cmd_duration = {
        min_time = 2000;
        style = "yellow";
      };

      fill = {
        symbol = " ";
      };

      character = {
        success_symbol = "[❯](bold green)";
        error_symbol = "[❯](bold red)";
      };

      time = {
        disabled = false;
        format = "[$time]($style)";
        time_format = "%R";
        style = "bg:none fg:grey";
      };
    };
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    enableZshIntegration = true;
  };
}
