{ ... }:
let
  # Hermes 用 GitHub App installation token を gh に渡す。
  # PATH 上のどの gh が動いても GH_TOKEN が最優先で使われるため、
  # シェル設定の読み込み順や PATH の並びに依存しない。
  ghAppTokenInit = ''
    # GitHub App installation token（発行スクリプトはキャッシュ付き）
    if [ -x "$HOME/bin/ghapp-token" ]; then
      _ghtok=$("$HOME/bin/ghapp-token" 2>/dev/null) && [ -n "$_ghtok" ] && export GH_TOKEN="$_ghtok"
      unset _ghtok
    fi
  '';
in
{
  programs.zsh.initContent = ghAppTokenInit;
  programs.bash.initExtra = ghAppTokenInit;
}
