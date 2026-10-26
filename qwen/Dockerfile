# =====================================================================
# 镜像：基于 eugr/spark-vllm-b12x:latest，内置 Qwen3.8-Flash-Next-FP4
#       的全部运行时环境变量与 vllm serve 启动命令。
#
# 将原 `docker run` 后在容器内 `export` 的变量烘焙为 ENV，
# 并把 `vllm serve ...` 设为 ENTRYPOINT（经由 entrypoint.sh 包装），
# 使镜像可直接由 docker compose 拉起，无需再手动 export 或手输参数。
#
# 模型路径与服务名通过 docker compose 的 command: 传入（值来自 .env），
# 与 prepare.sh 的下载路径 $DSH_DEPLOY_HOME/models/<MODEL_ID> 对齐
# （宿主机 $DSH_DEPLOY_HOME/models 挂载到容器 /models）。
# 镜像本身不含模型路径——同一镜像可服务不同模型，无需重新编译。
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
# 入口：entrypoint.sh 接收两个位置参数：$1=模型路径, $2=服务名。
# CMD 提供默认值（独立 docker run 时生效）；
# docker compose 通过 command: 覆盖（值来自 .env，由 prepare.sh 写入）。
# exec 确保信号正确传递；JSON 配置串在脚本内用单引号包裹。
# ---------------------------------------------------------------------
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
# 默认参数：模型路径, 服务名。docker compose 通过 command: 覆盖。
CMD ["/models/nvidia/Qwen3.8-Flash-Next-FP4-Local", "qwen3.8-flash"]
