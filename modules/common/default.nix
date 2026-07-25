{ pkgs, ... }:

{
  imports = [
    ./shell.nix
    ./git.nix
  ];

  home.packages = with pkgs; [
    git
    git-secrets
    gh
    ghq
    lazygit
    fzf
    bat
    devenv
    awscli2
    uv
    nodejs_24
    npm-check-updates
    opentofu  # Cloudflare の設定を宣言的に管理する（terraform は BUSL で unfree）
    hackgen-nf-font
  ];
}
