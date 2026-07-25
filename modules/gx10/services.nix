{ pkgs, ... }:
let
  # vLLM サービスの共通形。ConditionPathExists により、起動スクリプトが
  # 存在するマシンでのみ有効になる（gx10-1 / gx10-2 を同一 flake のまま分岐）
  mkVllmService = desc: script: {
    Unit = {
      Description = desc;
      ConditionPathExists = script;
      After = [ "network-online.target" ];
    };
    Service = {
      ExecStart = script;
      Restart = "on-failure";
      RestartSec = 15;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
in
{
  systemd.user.services = {
    qwen-vllm = mkVllmService "vLLM Qwen3.6-35B (Hermes default model, port 8080)" "%h/bin/qwen-serve.sh";
    laguna-vllm = mkVllmService "vLLM Laguna S 2.1 (port 8000)" "%h/bin/laguna-serve.sh";

    # PR レビューパイプライン（機械層）のフォールバック巡回。
    # 主経路は GitHub webhook → gh-gatekeeper.py が当該 PR だけを即時発火する。
    # これはその取りこぼしを毎時拾う保険。実装は dgx-control の scripts/pr-review.py。
    pr-review = {
      Unit = {
        Description = "PR review sweep (fallback for missed webhooks)";
        ConditionPathExists = "%h/bin/pr-review.py";
        After = [ "network-online.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "%h/bin/pr-review.py";
        # gh は installation token（hosts.yml、30分ごとに更新）を使う。
        # PEM を読むシム（~/bin/gh）は使わない —— 機械層に秘密鍵を触らせない方針。
        Environment = "GH_BIN=%h/.nix-profile/bin/gh";
        # 長い diff でも次の発火までに必ず終わらせる
        TimeoutStartSec = "3300";
      };
    };
  };

  systemd.user.services.cloudflared-tunnel = {
    Unit = {
      Description = "Cloudflare Tunnel";
      # トークンを置いた機体でのみ起動する。秘密をこのリポジトリに入れずに
      # 機体分岐できるので、vLLM サービスの ConditionPathExists と同じ作法になる。
      ConditionPathExists = "%h/.config/cloudflared/env";
      After = [ "network-online.target" ];
    };
    Service = {
      # TUNNEL_TOKEN=... を 600 で置く（リポジトリには入れない）
      EnvironmentFile = "%h/.config/cloudflared/env";
      # 更新は nix 側で行うので自動更新は切る
      ExecStart = "${pkgs.cloudflared}/bin/cloudflared --no-autoupdate tunnel run";
      Restart = "on-failure";
      RestartSec = 15;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  systemd.user.timers.pr-review = {
    Unit = {
      Description = "Hourly PR review sweep";
      ConditionPathExists = "%h/bin/pr-review.py";
    };
    Timer = {
      OnCalendar = "hourly";
      Persistent = true;
      # 毎時00分に集中させない（vLLM の負荷が他と衝突しないように）
      RandomizedDelaySec = 300;
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
