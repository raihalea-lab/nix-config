{ ... }:

{
  homebrew = {
    enable = true;

    onActivation = {
      autoUpdate = true;
      upgrade = true;
      cleanup = "zap";
    };

    taps = [
      "k1Low/tap"
      "docker/tap"
    ];

    brews = [
      "k1Low/tap/mo"
    ];

    casks = [
      "docker/tap/sbx"
      "ghostty"
      "linear"
      "zoom"
      "blackhole-2ch"
      "cmux"
      "tailscale-app"
      "windows-app"
      "antigravity-cli"
    ];

    masApps = {
      # "Xcode" = 497799835;
    };
  };
}
