{ pkgs, ... }:

{
  home.packages = with pkgs; [
    # WSL専用パッケージをここに追加
    unzip
    jq
    chromium

    # --- CUDA アプリ (llama.cpp 等) のビルド用ツールチェーン ---
    # nvcc 本体 (cuda-toolkit-13-0) だけは apt で入れる。
    # WSL の GPU は Windows 側ドライバを /usr/lib/wsl/lib 経由で使う都合上、
    # Toolkit のバージョンをホストに合わせる必要があり Nix 管理に向かないため。
    cmake
    gcc # CUDA 13.0 の host compiler は GCC 15 までサポート
    ccache
    pkg-config
    curl.dev # libcurl のヘッダ (apt の libcurl4-openssl-dev 相当)
  ];

  # curl.dev などが置く .pc ファイルを pkg-config / CMake から見つけられるようにする
  home.sessionVariables = {
    PKG_CONFIG_PATH = "$HOME/.nix-profile/lib/pkgconfig\${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}";
  };
}
