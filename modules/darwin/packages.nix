{ pkgs, ... }:

{
  home.packages = with pkgs; [
    docker
    docker-buildx
    colima
    ncdu
    sox
  ];
}
