{ pkgs, ... }:

{
  home.packages = with pkgs; [
    unzip
    jq
    tmux
    ripgrep
    ffmpeg
    cloudflared  # Cloudflare Tunnel（systemd user service は services.nix）
  ];
}
