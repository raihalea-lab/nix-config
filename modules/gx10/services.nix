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

  # GitHub Actions の self-hosted runner。無料枠を使い切ったので手元で回す。
  # イメージ定義は dgx-control の scripts/gh-runner.Dockerfile が正。
  #
  # コンテナ越しに動かすのは資源制限のためではなく隔離のため。ジョブはリポジトリ内の
  # 任意コードを raiha 権限で実行するので、ベアメタルだと sudo で ghapp-token を叩いて
  # GitHub App トークンを発行でき、~/.hermes と ~/.config/gh も読めてしまう。
  # cpu/memory の上限は、同居する音声入力スタックと vLLM の取り分を守るためのもの。
  systemd.user.services.gh-runner = {
    Unit = {
      Description = "GitHub Actions self-hosted runner (containerized)";
      # config.sh 済みの機体でのみ起動する。cloudflared-tunnel と同じ作法。
      ConditionPathExists = "%h/actions-runner/.credentials";
      After = [ "network-online.target" ];
    };
    Service = {
      # docker は apt 側を使う。デーモンが apt 管理なので CLI もそちらに揃える。
      ExecStartPre = "-/usr/bin/docker rm -f gh-runner";
      ExecStart = "/usr/bin/docker run --rm --name gh-runner --cpus=8 --memory=24g --memory-swap=24g -v %h/actions-runner:/home/runner/actions-runner gh-runner ./run.sh";
      # 実行中のジョブを片付ける時間を与えてから落とす
      ExecStop = "/usr/bin/docker stop -t 60 gh-runner";
      TimeoutStopSec = 90;
      # 再起動直後は dockerd がまだ上がっていないことがある。user unit から
      # system unit の docker.service へ After= は張れないのでリトライで待つ。
      Restart = "always";
      RestartSec = 15;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # ---------------------------------------------------------------------------
  # ステータスページ（status.raiha.dev / checks.raiha.dev、dgx-control 管理）
  #
  # Beszel = マシンメトリクス（CPU/メモリ/GPU/ディスク）、Gatus = サービス死活。
  # hub と gatus は gx10-2 の loopback で待ち、cloudflared だけが唯一の入口
  # （Access の aud_tag 検証付き）。agent は hub の SSH 公開鍵で署名検証するので
  # tailnet に開いていても無認証では読めない。
  # 起動スイッチは env ファイルの有無（cloudflared-tunnel と同じ作法）:
  #   beszel-agent … 両機。LISTEN（gx10-1 は Tailscale IP、gx10-2 は loopback）と KEY
  #   beszel-hub / gatus … gx10-2 のみ
  # ---------------------------------------------------------------------------
  systemd.user.services.beszel-agent = {
    Unit = {
      Description = "Beszel agent (system metrics)";
      ConditionPathExists = "%h/.config/beszel/agent.env";
      After = [ "network-online.target" ];
    };
    Service = {
      # LISTEN=<ip:port> と KEY=<hub 公開鍵> を 600 で置く
      EnvironmentFile = "%h/.config/beszel/agent.env";
      # GPU メトリクスは /usr/bin/nvidia-smi を PATH から探すため明示する
      Environment = "PATH=/usr/bin:/bin";
      ExecStart = "${pkgs.beszel}/bin/beszel-agent";
      Restart = "on-failure";
      RestartSec = 15;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  systemd.user.services.beszel-hub = {
    Unit = {
      Description = "Beszel hub (status.raiha.dev)";
      ConditionPathExists = "%h/.config/beszel/hub.env";
      After = [ "network-online.target" ];
    };
    Service = {
      EnvironmentFile = "%h/.config/beszel/hub.env";
      ExecStart = "${pkgs.beszel}/bin/beszel-hub serve --http 127.0.0.1:8090 --dir %h/.local/share/beszel";
      Restart = "on-failure";
      RestartSec = 15;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  systemd.user.services.gatus = {
    Unit = {
      Description = "Gatus (checks.raiha.dev service health)";
      ConditionPathExists = "%h/.config/gatus/env";
      After = [ "network-online.target" ];
    };
    Service = {
      # 中身は空でよい（機体スイッチ）。将来トークン等が要る時もここへ
      EnvironmentFile = "%h/.config/gatus/env";
      Environment = "GATUS_CONFIG_PATH=%h/.config/gatus/config.yaml";
      ExecStart = "${pkgs.gatus}/bin/gatus";
      Restart = "on-failure";
      RestartSec = 15;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # Gatus の監視定義。vLLM はキー無しで叩き 401 を「生存」とみなす
  # （API キーを監視設定に置かないため）。localhost バインドのサービス
  # （kotoba-asr / hermes 本体）は gx10-2 から届かないので、hermes は
  # hooks.raiha.dev の外形監視で代替する。
  xdg.configFile."gatus/config.yaml".text = ''
    web:
      address: 127.0.0.1
      port: 8091

    endpoints:
      - name: vLLM Laguna S 2.1
        group: gx10-2
        url: "http://localhost:8000/v1/models"
        interval: 60s
        conditions:
          - "[STATUS] == 401"

      - name: Open WebUI
        group: gx10-2
        url: "http://localhost:3000"
        interval: 60s
        conditions:
          - "[STATUS] == 200"

      - name: vLLM Qwen3.6
        group: gx10-1
        url: "http://100.91.149.123:8080/v1/models"
        interval: 60s
        conditions:
          - "[STATUS] == 401"

      - name: voice-bridge
        group: gx10-1
        url: "http://100.91.149.123:18000"
        interval: 60s
        conditions:
          - "[CONNECTED] == true"

      # gx10-1 の Tunnel と hermes gateway の生存を外形で確認（404 でも生存）。
      # CONNECTED が無いと接続失敗（STATUS=0）が "< 500" を素通りして up 扱いになる
      - name: hooks.raiha.dev
        group: external
        url: "https://hooks.raiha.dev"
        interval: 300s
        conditions:
          - "[CONNECTED] == true"
          - "[STATUS] < 500"
  '';

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
