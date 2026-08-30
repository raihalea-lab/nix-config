{ pkgs, ... }:

{
  home.packages = with pkgs; [
    unzip
    jq
    tmux
    ripgrep
    ffmpeg
    python3Packages.huggingface-hub  # hf / huggingface-cli（HF Hub からのモデル取得）
    cloudflared  # Cloudflare Tunnel（systemd user service は services.nix）
    beszel       # マシンメトリクス監視（hub + agent。services.nix 参照）
    gatus        # サービス死活監視（services.nix 参照）
  ];
}
