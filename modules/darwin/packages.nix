{ pkgs, ... }:

{
  home.packages = with pkgs; [
    docker
    docker-buildx
    docker-sbx
    colima
    ncdu
    sox
  ];
}
