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

  # 2026-07-30 から本番は DeepSeek-V4（2台 TP=2）。旧3モデルは**両機のメモリを
  # 明け渡さないと DeepSeek が載らない**ので自動起動しない。
  # 戻したいときは各機で `touch ~/.config/vllm/legacy-models` して再起動する
  # （ConditionPathExists は AND なので、スクリプトとマーカーの両方が要る）。
  mkLegacyVllmService = desc: script: (mkVllmService desc script) // {
    Unit = {
      Description = desc;
      ConditionPathExists = [ script "%h/.config/vllm/legacy-models" ];
      After = [ "network-online.target" ];
    };
  };
in
{
  systemd.user.services = {
    # ⚠️ 本番モデル。**両機で同じユニットが動き、rank は自分の QSFP IP から判定する**
    #    （192.168.100.1 = head / .2 = worker）。head から worker を SSH で起こさない
    #    設計なので、順序は問わない（先に上がった側が待ち合わせる）。
    #    起動に約8分（重み 166.9GB のロード + CUDA graph）。
    #    詳細は dgx-control の docs/deepseek-v4-dual.md。
    deepseek-vllm = {
      Unit = {
        Description = "vLLM DeepSeek-V4-Flash 2-node TP=2 (port 8888)";
        ConditionPathExists = "%h/bin/deepseek-serve.sh";
        After = [ "network-online.target" ];
      };
      Service = {
        ExecStart = "%h/bin/deepseek-serve.sh";
        # ⚠️ always にする。docker や RoCE がまだ整っていない段階では起動前検査が
        #    exit 64 で止まるので、条件が整うまで再試行させる。
        Restart = "always";
        RestartSec = 30;
      };
      Install.WantedBy = [ "default.target" ];
    };

    # ⚠️ **API の応答で死活を判定する。** 2026-07-30、NCCL の collective timeout で
    #    engine が死んだのにコンテナは Up のまま残り、`Restart=always` が発火せず
    #    `is-active` も active を返し続けた（7時間気づけなかった）。
    #    プロセスの生死では検出できないので、外から API を叩いて判定する。
    deepseek-healthcheck = {
      Unit = {
        Description = "DeepSeek API health check (restarts a wedged engine)";
        ConditionPathExists = "%h/bin/deepseek-healthcheck.sh";
      };
      Service = {
        Type = "oneshot";
        ExecStart = "%h/bin/deepseek-healthcheck.sh";
      };
    };

    # Vision-Exp（Docker Compose）用の死活監視。2026-09-04 に本番を 0731 から
    # 移行した際、`deepseek-healthcheck` 相当が空いたので埋めた。
    # ⚠️ compose の `restart: unless-stopped` はプロセス死しか拾わない。
    #    engine が刺さってもコンテナは Up のままなので、外から生成させて判定する。
    # ⚠️ head（gx10-1）だけで動く。TP=2 はどちらのランクが落ちても生成できなくなるし、
    #    復旧も上流 launcher が SSH で両ランクを面倒みるため。機体判別は
    #    ConditionPathExists（スクリプトは gx10-1 にしか置かない）。
    vision-exp-healthcheck = {
      Unit = {
        Description = "Vision-Exp generation health check (restarts both ranks)";
        ConditionPathExists = "%h/bin/vision-exp-healthcheck.sh";
      };
      Service = {
        Type = "oneshot";
        ExecStart = "%h/bin/vision-exp-healthcheck.sh";
        # 再起動は stop→start で10分前後かかる。oneshot が途中で殺されないように
        TimeoutStartSec = "30min";
      };
    };

    qwen-vllm = mkLegacyVllmService "vLLM Qwen3.6-35B (port 8080, legacy)" "%h/bin/qwen-serve.sh";
    laguna-vllm = mkLegacyVllmService "vLLM Laguna S 2.1 (port 8000, legacy)" "%h/bin/laguna-serve.sh";
    # llama.cpp だが起動の形は vLLM 勢と同一（スクリプト存在で機体判別、Restart 付き）
    fable-llama = mkLegacyVllmService "llama.cpp Fable-Fusion 27B creative (port 8081, legacy)" "%h/bin/fable-serve.sh";

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
  #
  # ephemeral（org JIT）方式：ExecStartPre がジョブごとに使い捨ての JIT config を
  # raihalea-lab org から発行（~/bin/gh-runner-jitconfig、dgx-control 管理）。
  # ランナーは1ジョブ実行後に GitHub 側が自動 deregister → コンテナ終了 →
  # Restart=always が次の発行・待機を回す。「常駐リスナーだが毎ジョブまっさら」になる。
  #
  # マウント設計（テスト環境のクリーンさと隔離の本体）:
  #   /runner-src   … runner 本体を **ro**。コンテナ内へコピーして実行するので、
  #                   ジョブからホスト側バイナリの改ざん・永続化ができない
  #   /jitconfig    … 使い捨て設定を ro。登録用トークンはコンテナに渡さない
  #   ~/.npm, ~/.cache … ダウンロードキャッシュのみ永続（node_modules は毎回組み直し）
  #   _work はコンテナ内 = ジョブ終了で消滅
  systemd.user.services.gh-runner = {
    Unit = {
      Description = "GitHub Actions ephemeral runner (containerized, org JIT)";
      # JIT 発行スクリプトを配置した機体でのみ起動する。cloudflared-tunnel と同じ作法。
      ConditionPathExists = "%h/bin/gh-runner-jitconfig";
      After = [ "network-online.target" ];
    };
    Service = {
      # docker は apt 側を使う。デーモンが apt 管理なので CLI もそちらに揃える。
      ExecStartPre = [
        "-/usr/bin/docker rm -f gh-runner"
        # キャッシュ置き場が無いと docker が root で作ってしまうので先に作る
        "/usr/bin/mkdir -p %h/actions-runner-cache/npm %h/actions-runner-cache/cache"
        # JIT config を発行（失敗時は RestartSec 後に再試行）
        "%h/bin/gh-runner-jitconfig"
      ];
      ExecStart = "/usr/bin/docker run --rm --name gh-runner --cpus=8 --memory=24g --memory-swap=24g -v %h/actions-runner:/runner-src:ro -v %h/.config/gh-runner/jitconfig:/jitconfig:ro -v %h/actions-runner-cache/npm:/home/runner/.npm -v %h/actions-runner-cache/cache:/home/runner/.cache gh-runner /runner-src/run-jit.sh";
      # 実行中のジョブを片付ける時間を与えてから落とす
      ExecStop = "/usr/bin/docker stop -t 60 gh-runner";
      TimeoutStopSec = 90;
      # ジョブ完了ごとの正常終了も、起動直後に dockerd が未起動のケースも Restart=always で回す
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
      # ⚠️ **本番モデル。API の応答で見ること。** 2026-07-30、NCCL の collective
      #    timeout で engine が死んだのにコンテナは Up のままで、プロセス監視では
      #    7時間気づけなかった。401 が返る = 認証まで到達している = 生きている。
      #    ⚠️ 起動に10分前後かかるので、再起動直後の赤は正常。
      - name: DeepSeek-V4 (2台 TP=2)
        group: gx10-1
        url: "http://192.168.100.1:8888/v1/models"
        interval: 60s
        conditions:
          - "[STATUS] == 401"

      - name: Open WebUI
        group: gx10-2
        url: "http://localhost:3000"
        interval: 60s
        conditions:
          - "[STATUS] == 200"

      # ⚠️ Qwen / Fable / Laguna は 2026-07-30 から**自動起動しない**（DeepSeek が
      #    両機のメモリを占有するため）。監視を残すと常時赤になるので外した。
      #    `~/.config/vllm/legacy-models` を作って戻したときは、ここも戻すこと。

      - name: voice-bridge
        group: gx10-1
        url: "http://192.168.100.1:18000"
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

      # コーディングエージェントのチャット UI（loopback なので外形は Tunnel 越し）
      - name: code.raiha.dev
        group: external
        url: "https://code.raiha.dev"
        interval: 300s
        conditions:
          - "[CONNECTED] == true"
          - "[STATUS] < 500"
  '';

  # ---------------------------------------------------------------------------
  # コーディングエージェント（dgx-control の docs/coding-agent.md）
  #
  # 設計の芯は「エージェントに資格情報を持たせない」こと。
  #   agent-proxy … vLLM の実キーを保持し、コンテナには使い捨てトークンだけ見せる。
  #                 docker ブリッジ gateway で待つ（loopback だとコンテナから届かず、
  #                 0.0.0.0 だと tailnet に開く。--network host は論外で、
  #                 ホストの hermes gateway(8644) にコンテナが届いてしまう）
  #   agent-chat  … OpenCode web（code.raiha.dev）。loopback に publish し、
  #                 cloudflared + Access が唯一の入口
  # push と PR 作成は機械層（~/bin/agent-implement.py）だけが行う。
  # ---------------------------------------------------------------------------
  systemd.user.services.agent-proxy = {
    Unit = {
      Description = "LLM proxy for the coding agent (holds the real API key)";
      ConditionPathExists = "%h/bin/agent-proxy.py";
      After = [ "network-online.target" ];
    };
    Service = {
      ExecStart = "%h/bin/agent-proxy.py";
      Restart = "on-failure";
      RestartSec = 15;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  systemd.user.services.agent-chat = {
    Unit = {
      Description = "OpenCode web for the coding agent (code.raiha.dev)";
      # チャット用エントリを配置した機体でのみ起動する
      ConditionPathExists = "%h/agent-runner/chat-entry.sh";
      After = [ "network-online.target" ];
    };
    Service = {
      ExecStartPre = [
        "-/usr/bin/docker rm -f agent-chat"
        "/usr/bin/mkdir -p %h/agent-workspace %h/agent-state"
      ];
      # ⚠️ 資格情報は渡さない。GitHub トークンも vLLM の実キーも入れない
      #    （LLM は proxy 経由、PR 化は機械層経由）。
      # ⚠️ docker socket をマウントしないこと。マウントした時点で隔離は無効になる。
      ExecStart = ''
        /usr/bin/docker run --rm --name agent-chat \
          --cpus=4 --memory=8g --memory-swap=8g --pids-limit 512 \
          --security-opt no-new-privileges --cap-drop ALL \
          --env-file %h/.config/agent-proxy/run-token.env \
          -p 127.0.0.1:8790:8790 \
          -v %h/agent-workspace:/workspaces \
          -v %h/agent-state:/state \
          -v %h/agent-runner/chat-entry.sh:/entry.sh:ro \
          -v %h/agent-runner/opencode.json:/home/agent/.config/opencode/opencode.json:ro \
          agent-runner
      '';
      ExecStop = "/usr/bin/docker stop -t 20 agent-chat";
      TimeoutStopSec = 40;
      Restart = "always";
      RestartSec = 15;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # 軽量な自動実装の経路。Linear の `hermes-go` を巡回して PR まで作る。
  # 対話でがっつり書きたいときは code.raiha.dev（agent-chat）を使う。
  systemd.user.services.agent-implement = {
    Unit = {
      Description = "Implement Linear tickets labelled hermes-go";
      ConditionPathExists = "%h/.config/linear/api-key";
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/bin/agent-implement.py";
      Environment = "GH_BIN=%h/.nix-profile/bin/gh";
      # エージェントループは1件で最大45分。次の発火までに終わらせる
      TimeoutStartSec = "3300";
    };
  };

  # ⚠️ **「GitHub App の権限管理だけで全ての環境が揃う」を成立させているのがこれ。**
  # App のインストール範囲と ~/agent-workspace を突き合わせ、増えたリポジトリの
  # 作業ツリーを作って code.raiha.dev の一覧に出す。外れたものは退避する。
  # 人が用意する手順は無い（App の設定画面が唯一の管理点）。
  systemd.user.services.agent-sync-workspaces = {
    Unit = {
      Description = "Sync chat workspaces with the GitHub App installation";
      ConditionPathExists = "%h/agent-runner/chat-entry.sh";
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/bin/agent-implement.py --sync-workspaces";
      Environment = "GH_BIN=%h/.nix-profile/bin/gh";
      TimeoutStartSec = "1800";
    };
  };

  # ⚠️ 3分ごと。連続4回失敗（=12分）で初めて再起動する。起動に10分前後かかるので、
  #    1回の失敗で再起動すると起動し直しのループに入る（スクリプト側にも猶予あり）。
  # Vision-Exp 用。間隔は deepseek-healthcheck と同じ3分
  # （スクリプト側が連続4回=12分で初めて再起動する）。
  systemd.user.timers.vision-exp-healthcheck = {
    Unit = {
      Description = "Check Vision-Exp generation health";
      ConditionPathExists = "%h/bin/vision-exp-healthcheck.sh";
    };
    Timer = {
      # 起動に6〜10分かかるので、ブート直後は見に行かない
      OnBootSec = "15min";
      OnUnitInactiveSec = "3min";
      Persistent = false;
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  systemd.user.timers.deepseek-healthcheck = {
    Unit = {
      Description = "Check DeepSeek API health";
      ConditionPathExists = "%h/bin/deepseek-healthcheck.sh";
    };
    Timer = {
      OnBootSec = "15min";
      OnUnitInactiveSec = "3min";
      Persistent = false;
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  systemd.user.timers.agent-implement = {
    Unit = {
      Description = "Poll Linear for implementation work";
      ConditionPathExists = "%h/.config/linear/api-key";
    };
    Timer = {
      OnBootSec = "10min";
      OnUnitInactiveSec = "15min";
      Persistent = true;
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  systemd.user.timers.agent-sync-workspaces = {
    Unit = {
      Description = "Hourly workspace sync";
      ConditionPathExists = "%h/agent-runner/chat-entry.sh";
    };
    Timer = {
      # 起動直後にも1回走らせる（リブートを跨いで App の変更を取り込むため）
      OnBootSec = "5min";
      OnUnitInactiveSec = "1h";
      Persistent = true;
      RandomizedDelaySec = 300;
    };
    Install = {
      WantedBy = [ "timers.target" ];
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
