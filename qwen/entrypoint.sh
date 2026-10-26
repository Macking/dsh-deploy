#!/bin/sh
# entrypoint.sh — vllm serve 入口（由 Dockerfile COPY 进镜像）。
#
# 用法： /entrypoint.sh <模型路径> <服务名>
#   $1 = 模型路径（容器内，如 /models/nvidia/Qwen3.8-Flash-Next-FP4-Local）
#   $2 = 模型服务名（vllm --served-model-name 的值，如 qwen3.8-flash）
#
# Dockerfile 通过 CMD 提供默认值（独立 docker run 时生效）；
# docker compose 通过 command: 覆盖，值来自 .env
# （MODEL_ID、SERVED_MODEL_NAME，由 prepare.sh 写入）。
# 宿主机 $DSH_DEPLOY_HOME/models 挂载到容器 /models，
# 模型实际位于 /models/<MODEL_ID>，与 prepare.sh 下载路径对齐。
#
# 其余启动参数固定，与原 docker run 命令完全一致。
# JSON 配置串用单引号包裹，避免 shell 对内部双引号的转义问题。
# exec 确保 vllm 取代本 shell 成为 PID 1，正确接收信号。
exec vllm serve "${1:?用法: entrypoint.sh <模型路径> <服务名>}" \
  --host 0.0.0.0 \
  --port 8000 \
  --served-model-name "${2:?用法: entrypoint.sh <模型路径> <服务名>}" \
  --tensor-parallel-size 1 \
  --pipeline-parallel-size 1 \
  --mamba-cache-mode align \
  --enable-prefix-caching \
  --enable-chunked-prefill \
  --dtype bfloat16 \
  --kv-cache-dtype fp8 \
  --quantization modelopt_mixed \
  --block-size 16 \
  --load-format b12x \
  --max-model-len 262144 \
  --max-num-seqs 8 \
  --max-num-batched-tokens 4096 \
  --speculative-config '{"method":"mtp","num_speculative_tokens":4}' \
  --gdn-decode-kernel b12x \
  --linear-backend b12x \
  --moe-backend b12x \
  --no-enable-flashinfer-autotune \
  --mm-encoder-tp-mode data \
  --reasoning-parser qwen3 \
  --tool-call-parser qwen3_xml \
  --enable-auto-tool-choice \
  --compilation-config '{"pass_config":{"fuse_act_quant":true}}' \
  --gpu-memory-utilization 0.8
