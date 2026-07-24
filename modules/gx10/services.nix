{ ... }:
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
  };
}
