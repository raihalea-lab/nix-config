{ pkgs, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  username = "raiha";
  homePrefix = if isDarwin then "/Users" else "/home";
in
{
  home.username = username;
  home.homeDirectory = "${homePrefix}/${username}";
  home.stateVersion = "24.05";

  home.sessionVariables = {
    # EDITOR = "vim";
  };

  programs.home-manager.enable = true;
}
