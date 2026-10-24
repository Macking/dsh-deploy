# =====================================================================
# 镜像：基于 eugr/spark-vllm-b12x:latest，内置 Qwen3.8-Flash-Next-FP4
#       的全部运行时环境变量与 vllm serve 启动命令。
#
# 将原 `docker run` 后在容器内 `export` 的变量烘焙为 ENV，
# 并把 `vllm serve ...` 设为 ENTRYPOINT，使镜像可直接由
# docker compose 拉起，无需再手动 export 或手输参数。
#
# 构建：  docker build -t spark-vllm-b12x-qwen3.8-flash:latest .
# =====================================================================
FROM eugr/spark-vllm-b12x:latest

# ---------------------------------------------------------------------
# 环境变量：对应交互测试中 `export` 的全部变量（烘焙进镜像）。
# 新版 ENV 语法会自动去掉值两侧的引号，与 bash `export VAR="x"` 行为一致。
# ---------------------------------------------------------------------
ENV VLLM_PLE_TABLE_MEMORY="disk"
ENV B12X_DISK_BACKEND="io_uring"
ENV CUTE_DSL_ARCH="sm_121a"
ENV SAFETENSORS_FAST_GPU="1"
ENV VLLM_WORKER_MULTIPROC_METHOD="spawn"
ENV VLLM_SSM_CONV_STATE_LAYOUT="DS"
ENV VLLM_USE_AOT_COMPILE="1"
ENV VLLM_USE_MEGA_AOT_ARTIFACT="1"
ENV VLLM_USE_V2_MODEL_RUNNER="1"
ENV B12X_POLICY_MODE="auto"
ENV VLLM_MXFP8_LM_HEAD="1"
ENV VLLM_B12X_MOE_FP4_LAYER_MAX_INPUT_SCALE="w13"
ENV VLLM_B12X_MOE_FP4_FORCE_A16=1
ENV B12X_W4A16_A4_PREFILL=1
# 以下两个原为 `docker run -e` 传入，一并烘焙进镜像以保证镜像自包含。
ENV HF_HUB_OFFLINE=1
ENV HF_HOME=/root/.cache/huggingface

# ---------------------------------------------------------------------
# 入口：vllm serve
# 采用 exec（JSON 数组）形式：每个参数独立成元素，避免 shell 对
# --speculative-config / --compilation-config 中 JSON 串的引号转义问题。
# 行尾反斜杠为 Dockerfile 续行符，会被先合并成单行再按 JSON 解析。
# 顺序与原命令完全一致。
# ---------------------------------------------------------------------
ENTRYPOINT ["vllm", "serve", "/models/local/Qwen3.8-Flash-Next-FP4-Local", \
  "--host", "0.0.0.0", \
  "--port", "8000", \
  "--served-model-name", "qwen3.8-flash", \
  "--tensor-parallel-size", "1", \
  "--pipeline-parallel-size", "1", \
  "--mamba-cache-mode", "align", \
  "--enable-prefix-caching", \
  "--enable-chunked-prefill", \
  "--dtype", "bfloat16", \
  "--kv-cache-dtype", "fp8", \
  "--quantization", "modelopt_mixed", \
  "--block-size", "16", \
  "--load-format", "b12x", \
  "--max-model-len", "262144", \
  "--max-num-seqs", "8", \
  "--max-num-batched-tokens", "4096", \
  "--speculative-config", "{\"method\":\"mtp\",\"num_speculative_tokens\":4}", \
  "--gdn-decode-kernel", "b12x", \
  "--linear-backend", "b12x", \
  "--moe-backend", "b12x", \
  "--no-enable-flashinfer-autotune", \
  "--mm-encoder-tp-mode", "data", \
  "--reasoning-parser", "qwen3", \
  "--tool-call-parser", "qwen3_xml", \
  "--enable-auto-tool-choice", \
  "--compilation-config", "{\"pass_config\":{\"fuse_act_quant\":true}}", \
  "--gpu-memory-utilization", "0.8"]
