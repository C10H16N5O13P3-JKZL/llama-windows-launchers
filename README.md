# llama Windows Launchers

一组 Windows 启动与管理脚本：拖入 GGUF 启动 llama.cpp，支持 Vulkan GPU、独立 CPU、NVIDIA CUDA、Intel NPU，以及 llama.cpp 多版本安装、切换与回退。

仓库只包含脚本，不包含模型、llama.cpp 二进制、Python 虚拟环境或驱动。模型可以保存在任意文件夹，无需复制进仓库。

## 环境要求

- Windows x64，Windows PowerShell 5.1 或更高版本。`.bat` 默认调用系统的 `powershell.exe`。
- 更新运行时需要访问 GitHub；自动下载模型需要访问 Hugging Face。
- Vulkan 模式需要支持 Vulkan 的 GPU 和驱动；CPU 模式使用独立的 Windows x64 CPU 发行包。
- CUDA 模式使用官方 Windows x64 CUDA 12.4 发行包及其 cudart 依赖，需要兼容 CUDA 12.4 的 NVIDIA 显卡和驱动。脚本不安装驱动；随包部署运行库，不要求自行安装完整 CUDA Toolkit。
- NPU 模式需要受 OpenVINO 支持的 Intel NPU 和驱动。模型架构、量化方式和运行时版本都会影响支持情况与输出质量。
- GGUF 路径不需要 Python。可选的 OpenVINO GenAI 路径需要 PATH 中有 `python`，且该 Python 版本有对应 OpenVINO wheel。

## 快速开始：拖入 GGUF

下载或克隆仓库后，在仓库目录打开 PowerShell：

```powershell
# 首次安装 Vulkan 运行时，并设为默认版本
.\manage-llama.bat Update

# 加载任意位置的 GGUF
.\start-gguf.bat "E:\模型\model.gguf"
```

也可以将 `.gguf` 文件拖到 `start-gguf.bat` 图标上，或双击该脚本后输入完整路径。

默认从 **28080** 开始寻找可用端口，最多尝试 200 个连续端口。等待服务器成功监听后，打开控制台显示的地址，例如 `http://127.0.0.1:28080`。OpenAI 兼容 API 地址为该地址加 `/v1`。

```powershell
# 自定义起始端口、尝试次数、上下文大小
.\start-gguf.bat "E:\模型\model.gguf" -p 29000 -pt 100 -c 8192

# 使用 CPU
.\manage-llama.bat Update -b cpu
.\start-gguf.bat "E:\模型\model.gguf" -b CPU
```

包含空格的路径要加引号；相对路径以命令运行目录为基准。分片 GGUF 传入第一片，其余分片应在同一目录。

## 普通启动器

CPU、CUDA 有各自的快捷入口；安装一次后即可使用：

```powershell
.\manage-llama.bat Update -b cpu
.\start-cpu.bat -m "E:\模型\model.gguf"

.\manage-llama.bat Check -b cuda
.\manage-llama.bat Update -b cuda
.\start-cuda.bat -m "E:\模型\model.gguf" -ap

# 拖入入口也支持 CUDA；自动尝试端口
.\start-gguf.bat "E:\模型\model.gguf" -b CUDA
```

`start-cpu.bat` / `start-cuda.bat` 接受 `-m` 等普通启动参数，默认固定端口 28080，可加 `-ap`。拖放文件仍使用 `start-gguf.bat`。`-b iGPU` 与 `-b Vulkan` 都选择 Vulkan 运行时；实际使用哪块 Vulkan GPU 取决于 llama.cpp 的设备选择。

**旧版用户注意：** `-b CPU` 现在选择独立 CPU 运行时，需要先执行 `Update -b cpu`。CPU/CUDA 不会隐式回退到 Vulkan 安装。

```powershell
# Vulkan，固定端口 28080
.\start-server.bat -m "E:\模型\model.gguf"

# CPU，并自动寻找端口
.\start-server.bat -m "E:\模型\model.gguf" -b CPU -ap

# 只检查文件和预览参数，不加载模型
.\start-server.bat -m "E:\模型\model.gguf" -ap -d
```

`start-server` 不带 `-m` 时使用 `models/LFM3-1.7B-Q8_0.gguf`。仓库不附带或自动下载这个默认模型；首次使用请明确传入自己的 GGUF 路径。

端口探测区分“被占用”和“访问受限”。Windows 保留端口可能没有监听进程，但仍返回 `AccessDenied / 10013`。可用以下命令查看保留区间：

```powershell
netsh interface ipv4 show excludedportrange protocol=tcp
```

自动端口模式会跳过不能绑定的端口；探测后发生绑定冲突时，根据服务器绑定失败日志继续重试。模型加载失败不会触发端口重试。`-d` 不预留端口，实际启动时仍可能遇到竞争。

## Intel NPU

### GGUF / llama.cpp OpenVINO

```powershell
.\manage-llama.bat Update -b openvino
.\start-npu.bat -m "E:\模型\model.gguf"

# 内置别名：首次自动下载 LFM2.5-1.2B-Instruct-Q4_K_M.gguf
.\start-npu.bat -m lfm2.5
```

NPU 默认固定端口 **28081**，上下文 4096，并限制为单并行序列。它目前不提供自动端口重试；如冲突请使用 `-p` 指定其他端口。

`lfm2.5` 为默认模型别名。首次编译 NPU 图可能需要较长时间；GGUF 能被读取不等于该模型在 NPU 上受支持，请验证实际输出。不要将某一模型在 Vulkan/CPU 上的成功推理视为 NPU 兼容性保证。

### 可选：OpenVINO GenAI

```powershell
# 首次创建 ov-venv、安装依赖并下载模型
.\start-npu.bat -m qwen3-8b

# 已有 OpenVINO IR 模型目录
.\start-npu.bat -m "E:\模型\my-openvino-model" -mp 4096 -mr 2048
```

此路径使用 `tools/ov_server.py`，不使用 llama.cpp 运行时，因而不接受 `-v` 和 `-x`。首次自动安装使用 OpenVINO nightly 源和 `--pre`，依赖未锁定，后续上游变化可能影响兼容性。

GenAI 辅助服务提供 `/health`、`/v1/models` 和 `/v1/chat/completions`，支持流式输出，一次处理一个推理请求，没有 Web 聊天界面。它是轻量开发用服务，不提供完整的 OpenAI API 行为或鉴权；默认仅绑定 `127.0.0.1`。

## 版本管理

四种运行时分开管理：`-b vulkan`（默认）、`-b openvino`、`-b cpu`、`-b cuda`。各自独立安装、默认选择、回退和删除。

| 命令 | 作用 |
|---|---|
| `List` | 查看本地版本，`Active` 表示默认选择 |
| `Check` | 查询最新对应发行包，不下载 |
| `Install -v b编号` | 安装指定版本，不改变默认选择 |
| `Update` | 安装最新对应版本，并设为默认 |
| `Use -v b编号` | 切换到已安装版本 |
| `Use -v legacy` | 使用原始手动安装目录（存在时） |
| `Remove -v b编号` | 删除非当前选择的托管版本 |
| `Remove -v b编号 -d` | 预览删除位置 |

```powershell
.\manage-llama.bat List
.\manage-llama.bat Check -b openvino
.\manage-llama.bat Install -v b12142
.\start-server.bat -v b12142 -m "E:\模型\model.gguf"
.\manage-llama.bat Use -v b12142
.\manage-llama.bat Remove -v b11970 -d
```

版本号为示例，请按实际发行和安装情况替换。下载只来自 [llama.cpp 官方发行](https://github.com/ggml-org/llama.cpp/releases)。安装会检查包大小、官方 SHA256 摘要和 `llama-server --version`，成功后才保存为完整安装。缺少 SHA256 摘要的发行包会被拒绝。

CUDA 安装同时下载同一发行版的 `llama-...-bin-win-cuda-12.4-x64.zip` 与 `cudart-llama...-bin-win-cuda-12.4-x64.zip`，分别校验后将依赖 DLL 部署到程序旁边，完整依赖文件另保留在 `cuda-dependencies/`。两包均成功后才切换，依赖来源和摘要也写入 `install.json`。`Check -b cuda` 会显示两个包及其大小；CUDA 下载明显大于 CPU/Vulkan。当前不提供 CUDA 13.x 或 ARM64 版本选择。

`latest` 指最近提供对应 Windows x64 包的 build，可能包含预发布；脚本读取发行列表，而不依赖可能没有程序包的 `/releases/latest`。

```text
llama-versions/
  vulkan/
    current.txt         默认版本编号
    b12142/
      install.json      来源、校验值、安装时间、版本输出
      llama-server.exe
  openvino/
    current.txt
    b12142/
  cpu/
    current.txt
    b12142/
  cuda/
    current.txt
    b12142/
llama-vulkan/           可选的原始安装，称为 legacy
llama-openvino/         可选的原始安装，称为 legacy
llama-cpu/              可选的原始 CPU 安装
llama-cuda/             可选的原始 CUDA 安装（含运行库）
```

启动器优先使用显式 `-v`，否则读取 `current.txt`，没有指针时回退到 `legacy`。**新克隆的仓库没有 legacy，请先运行 Update。** `Install` 不切换，安装后需 `Use` 或通过启动参数 `-v` 选择。

切换仅影响下次启动，不会停止或重启现有服务。删除前应停止该版本进程；脚本拒绝删除当前默认版本、检测到正在运行的版本、包含目录链接的版本和 `legacy`。遇到文件占用可能部分删除失败，释放占用后重试。版本管理不修改模型、NPU 驱动或 GenAI 虚拟环境。

## 帮助与短参数

```powershell
.\manage-llama.bat Help
.\manage-llama.bat -h
.\start-server.bat -h
.\start-npu.bat -h
.\start-gguf.bat -h
```

| 简写 | 完整参数 | 适用范围 |
|---|---|---|
| `-h` | `-Help` | 所有入口 |
| `-a` | `-Action` | 版本管理；命令也可直接作为首参数 |
| `-b` | `-Backend` | 管理器：vulkan/openvino/cpu/cuda；普通启动器：iGPU/Vulkan/CPU/CUDA |
| `-v` | `-Version` | 管理器、GGUF 启动器 |
| `-m` | `-Model` | 普通和 NPU 启动器；拖入入口直接传路径 |
| `-p` | `-Port` | 启动器 |
| `-c` | `-Ctx` | GGUF 上下文大小 |
| `-addr` | `-HostAddr` | 绑定地址，默认 127.0.0.1 |
| `-d` | `-DryRun` | 启动器预览；管理器仅 Remove |
| `-ap` | `-AutoPort` | 普通启动器；拖入入口自动启用 |
| `-pt` | `-PortAttempts` | 自动端口最大尝试数，默认 200 |
| `-x` | `-ExtraArgs` | llama 原生参数，需通过 `.ps1` 传数组 |
| `-mp` / `-mr` | `-MaxPrompt` / `-MaxResponse` | GenAI 静态长度限制 |

`.bat` 会在结束时暂停，便于查看错误。自动化调用可直接使用 `.ps1`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\manage-llama.ps1 List

# 在允许执行脚本的 PowerShell 会话中，直接传入数组
.\start-server.ps1 -m "E:\模型\model.gguf" -x @('--temp','0.7')
```

## 仓库内容与发布

离线集成测试（Windows PowerShell 5.1，无需 GPU 或下载模型）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test-backends.ps1
```

测试用小型模拟发行包验证 CPU/CUDA 安装、依赖部署、启动参数和 SHA256 失败回退，不替代真实显卡推理测试。

- `start-gguf.bat`：拖入和交互输入模型路径。
- `start-server.*`：Vulkan / CPU / CUDA 共用启动器。
- `start-cpu.bat` / `start-cuda.bat`：指定后端的快捷入口。
- `start-npu.*`：Intel NPU GGUF / GenAI 启动器。
- `manage-llama.*`：运行时版本管理。
- `tools/llama-runtime.ps1`：版本路径解析与 GGUF 文件头检查。
- `tools/llama-port.ps1`：端口探测和绑定错误识别。
- `tools/ov_server.py`：可选 GenAI HTTP 服务。

`.gitignore` 排除了下载的运行时、模型、虚拟环境、缓存和日志，上传时请保留这些排除项。本项目未附带许可证文件；发布者可按自己的授权意愿添加许可证。下载的第三方程序和模型遵循各自的许可证。
