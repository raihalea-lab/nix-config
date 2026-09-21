{ pkgs, ... }:

{
  home.packages = with pkgs; [
    docker
    docker-buildx
    colima
    ncdu
    sox
    coreutils  # timeout など GNU コマンド（プレフィックスなしで入る）
  ];
}
