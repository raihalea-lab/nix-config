{
  description = "Home Manager configuration for WSL, macOS, and NVIDIA DGX Spark";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # nix-darwin
    darwin.url = "github:LnL7/nix-darwin";
    darwin.inputs.nixpkgs.follows = "nixpkgs";

    # herdr (AIエージェント用tmux)
    # 上流はバイナリキャッシュを公開していないので毎回ソースビルドになる。
    # follows を付けないと herdr 側の古い nixpkgs が使われ、その世代の
    # importCargoLock が crates.io の API から取得して 403 で失敗する。
    herdr.url = "github:ogulcancelik/herdr";
    herdr.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, nixpkgs, home-manager, darwin, ... }: {

    # ---------------------------------------------------------------
    # 1. WSL用設定 (Home Manager Standalone)
    # コマンド: home-manager switch --flake .#wsl
    # ---------------------------------------------------------------
    homeConfigurations."wsl" = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages."x86_64-linux";
      modules = [
        ./home.nix
        ./modules/common
        ./modules/wsl
      ];
    };

    # ---------------------------------------------------------------
    # 2. NVIDIA DGX Spark (ASUS GX10) 用設定
    #    (Home Manager Standalone, aarch64)
    # コマンド: home-manager switch --flake .#gx10
    #
    # GB10 Grace Blackwell / ARM64 / DGX OS という固有の前提を含むため、
    # 汎用の Linux サーバーとは分けている。別の Linux を足すときは
    # ./modules/linux を新設し、共有分をそちらへ移すこと。
    # ---------------------------------------------------------------
    homeConfigurations."gx10" = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages."aarch64-linux";
      modules = [
        ./home.nix
        ./modules/common
        ./modules/gx10
      ];
    };

    # ---------------------------------------------------------------
    # 3. macOS用設定 (nix-darwin)
    # コマンド: nix run nix-darwin -- switch --flake .#raiha
    # ---------------------------------------------------------------
    darwinConfigurations."raiha" = darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        ./darwin.nix
        ./modules/darwin/homebrew.nix

        home-manager.darwinModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;

          home-manager.users."raiha" = { ... }: {
            imports = [
              ./home.nix
              ./modules/common
              ./modules/darwin
            ];
            home.packages = [ inputs.herdr.packages."aarch64-darwin".default ];
          };
        }
      ];
    };
  };
}
