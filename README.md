# llama Windows Launchers

一组 Windows 启动与管理脚本：双击或拖入 GGUF 即可运行 llama.cpp，支持 NVIDIA CUDA、Vulkan GPU、独立 CPU、Intel NPU，可选择服务器模式或终端对话模式，并管理 llama.cpp 多版本的安装、切换与回退。

仓库只包含脚本，不包含模型、llama.cpp 二进制、Python 虚拟环境或驱动。模型可以保存在任意文件夹，无需复制进仓库。

主目录只有两个可以直接双击的入口：

| 文件 | 作用 |
|---|---|
| `start-llama.bat` | **运行模型**：选模型、选后端、选对话/服务器模式 |
| `manage-llama.bat` | **管理运行时**：安装、更新、切换、删除 llama.cpp 版本 |

其余内容都收在子文件夹里：`tools/`（PowerShell 与 Python 脚本，不能直接双击）、`shortcuts/`（固定后端的快捷入口）、`tests/`。

## 环境要求

- Windows x64，Windows PowerShell 5.1 或更高版本。`.bat` 调用系统的 `powershell.exe`。
- 更新运行时需要访问 GitHub；自动下载模型需要访问 Hugging Face。
- Vulkan 需要支持 Vulkan 的 GPU 和驱动；CPU 使用独立的 Windows x64 CPU 发行包。
- CUDA 使用官方 Windows x64 CUDA 12.4 发行包及其 cudart 依赖，需要兼容的 NVIDIA 显卡和驱动。脚本不安装驱动；运行库随包部署，不要求安装完整 CUDA Toolkit。
- NPU 需要受 OpenVINO 支持的 Intel NPU 和驱动。模型架构、量化方式和运行时版本都会影响支持情况与输出质量。
- GGUF 路径不需要 Python。可选的 OpenVINO GenAI 路径需要 PATH 中有 `python`，且该版本有对应 OpenVINO wheel。

## 快速开始

1. **双击 `manage-llama.bat`**，输入数字（1 Vulkan、2 CUDA、3 CPU、4 OpenVINO/NPU）下载、校验并选用该后端的最新官方版本；可连续安装多个，输入 0 退出。
2. **双击 `start-llama.bat`**（或把 `.gguf` 拖到它上面），依次回答：
   - **模型**：列出模型文件夹（默认 `models/`）里的 GGUF，按编号选择，也可以粘贴或拖入任意完整路径；
   - **后端**：列出已安装的后端，第一项 Auto 为本机推荐（有 NVIDIA 显卡且装了 CUDA 则用 CUDA，否则 Vulkan，再否则 CPU）；只装了一个后端时不询问；
   - **模式**：Server（浏览器 Web 界面 + OpenAI 兼容 API）或 Chat（直接在当前窗口对话）；
   - **参数**：回车使用默认值（菜单里会显示当前的上下文大小和端口）；选 2 可逐项修改上下文大小、端口（仅服务器模式）和额外的 llama 原生参数（如 `--temp 0.7`，含空格的值用双引号括起），每一项回车同样保留默认。

每一步直接按回车即选第一项。如果还没有安装任何运行时，会先打开安装菜单，装好后继续。

已在命令行给出的项不再询问：

```powershell
# 全部指定，不提问
.\start-llama.bat "E:\模型\model.gguf" -b CUDA -Mode Chat

# 指定后端和上下文，模型与模式仍会询问
.\start-llama.bat -b CPU -c 8192

# Intel NPU
.\start-llama.bat "E:\模型\model.gguf" -b NPU
```

服务器模式默认从 **28080** 开始寻找可用端口，最多尝试 200 个连续端口。等待服务器成功监听后，打开控制台显示的地址，例如 `http://127.0.0.1:28080`；OpenAI 兼容 API 为该地址加 `/v1`。对话模式使用同一运行时里的 `llama-cli.exe`，按 Ctrl+C 退出。

包含空格的路径要加引号；相对路径以命令运行目录为基准。分片 GGUF 传入第一片，其余分片应在同一目录。在没有控制台输入的环境（管道、计划任务、CI）中不会等待输入：后端按 Auto、模式按 Server 处理，缺少模型则直接报错。

## 快捷入口（shortcuts/）

不想每次回答问题时，可以用 `shortcuts/` 里的固定入口，或给它们创建桌面快捷方式。它们都可以双击或拖入 `.gguf`：

| 文件 | 行为 |
|---|---|
| `start-gguf.bat` | 不提问：自动选后端，服务器模式，自动端口 |
| `start-cuda.bat` / `start-cpu.bat` / `start-server.bat` | 固定 CUDA / CPU / Vulkan，服务器模式；拖入时自动端口，否则固定 28080（可加 `-ap`） |
| `start-npu.bat` | Intel NPU，带模型别名和 OpenVINO GenAI（见下文） |

```powershell
.\shortcuts\start-cuda.bat -m "E:\模型\model.gguf" -ap
.\shortcuts\start-gguf.bat "E:\模型\model.gguf" -p 29000 -pt 100 -c 8192

# 只检查文件和预览参数，不加载模型
.\shortcuts\start-server.bat -m "E:\模型\model.gguf" -d
```

`-b iGPU` 与 `-b Vulkan` 都选择 Vulkan 运行时；实际使用哪块 Vulkan GPU 取决于 llama.cpp 的设备选择。各后端运行时互相独立，不会隐式回退到别的后端。

端口探测区分“被占用”和“访问受限”。Windows 保留端口可能没有监听进程，但仍返回 `AccessDenied / 10013`，可用以下命令查看保留区间：

```powershell
netsh interface ipv4 show excludedportrange protocol=tcp
```

自动端口模式会跳过不能绑定的端口；探测后发生绑定冲突时，根据服务器绑定失败日志继续重试。模型加载失败不会触发端口重试。`-d` 不预留端口，实际启动时仍可能遇到竞争。

## Intel NPU

### GGUF / llama.cpp OpenVINO

```powershell
.\manage-llama.bat Update -b openvino

# 自己的 GGUF：统一入口选 NPU 后端即可
.\start-llama.bat "E:\模型\model.gguf" -b NPU

# 内置别名：首次自动下载 LFM2.5-1.2B-Instruct-Q4_K_M.gguf 到模型文件夹
.\shortcuts\start-npu.bat -m lfm2.5
```

NPU 后端默认上下文 4096（不受配置文件 `ctx` 影响，可用 `-c` 指定），服务器模式限制为单并行序列。`start-npu.bat` 默认固定端口 **28081**，不自动重试端口，冲突时用 `-p` 指定；通过 `start-llama.bat` 启动则与其他后端一样自动找端口。

首次编译 NPU 图可能需要较长时间。GGUF 能被读取不等于该模型在 NPU 上受支持，请验证实际输出；不要将某一模型在 Vulkan/CPU 上的成功推理视为 NPU 兼容性保证。

已知现象：加载 `lfm2.5` 时日志中可能出现 `ggml-openvino: dynamic dim value mismatch for View node ...`。这是 llama.cpp OpenVINO 后端自身输出的信息，与启动脚本无关；实测该模型的生成结果未见异常，其他模型请自行验证。

### 可选：OpenVINO GenAI

```powershell
# 首次创建 ov-venv、安装依赖并下载模型
.\shortcuts\start-npu.bat -m qwen3-8b

# 已有 OpenVINO IR 模型目录
.\shortcuts\start-npu.bat -m "E:\模型\my-openvino-model" -mp 4096 -mr 2048
```

此路径使用 `tools/ov_server.py`，不使用 llama.cpp 运行时，因而不接受 `-v` 和 `-x`，也没有对话模式。首次自动安装使用 OpenVINO nightly 源和 `--pre`，依赖未锁定，后续上游变化可能影响兼容性。

GenAI 辅助服务提供 `/health`、`/v1/models` 和 `/v1/chat/completions`，支持流式输出，一次处理一个推理请求，没有 Web 聊天界面。它是轻量开发用服务，不提供完整的 OpenAI API 行为或鉴权；默认仅绑定 `127.0.0.1`。

## 本机配置与迁移

脚本本身不含任何本机路径。默认情况下运行时、模型和虚拟环境都放在脚本文件夹内，**整个文件夹可以直接复制或移动到其他位置、其他机器**。

需要把数据与脚本分开（例如运行时放大容量盘、多个克隆或 worktree 共用一份运行时、更新脚本时不动数据）时，复制 `launcher.config.example.json` 为 `launcher.config.json` 并修改。该文件不进入版本控制，所有项都可省略或留空：

| 设置 | 作用 | 默认 |
|---|---|---|
| `dataDir` | 存放 `llama-versions/`、legacy 目录、`ov-venv/` 的数据目录 | 脚本文件夹 |
| `modelsDir` | 模型文件夹：选择模型时列出其中的 GGUF；NPU 别名下载到这里 | `<dataDir>/models` |
| `defaultModel` | 默认 GGUF；相对路径以 `modelsDir` 为基准。`start-llama.bat` 询问时回车即选它，快捷入口不带模型时直接使用它 | 无 |
| `port` / `ctx` | 默认端口与上下文大小（NPU 的上下文除外） | 28080 / 16384 |

```json
{
  "dataDir": "D:/llama-data",
  "modelsDir": "E:/模型",
  "defaultModel": "model.gguf",
  "ctx": 8192
}
```

JSON 中路径用 `/` 或 `\\` 分隔；相对路径以脚本文件夹为基准；可使用 `%USERPROFILE%` 等环境变量。写错的设置名会直接报错。优先级：命令行参数 > 环境变量 `LLAMA_LAUNCHER_HOME`（仅覆盖 `dataDir`）> 配置文件 > 内置默认值。

迁移已有安装：把 `llama-versions/`（需要的话连同 `models/` 和 legacy 目录）移动到新位置，再把 `dataDir` 指向它即可，无需重新下载；`manage-llama.bat List` 会显示当前数据目录下的全部版本。Python 虚拟环境 `ov-venv/` 内含绝对路径，移动后请删除并让脚本重建。

下载相关的环境变量：`HTTPS_PROXY` 对 `curl.exe` 下载生效；`HF_ENDPOINT` 可指定 Hugging Face 镜像（NPU 模型别名下载使用）。

## 版本管理

四种运行时分开管理：`-b vulkan`（默认）、`-b openvino`、`-b cpu`、`-b cuda`。各自独立安装、默认选择、回退和删除。

| 命令 | 作用 |
|---|---|
| `List` | 查看本地版本，`Active` 表示默认选择；不带 `-b` 时列出全部后端 |
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
.\start-llama.bat "E:\模型\model.gguf" -b Vulkan -v b12142
.\manage-llama.bat Use -v b12142
.\manage-llama.bat Remove -v b11970 -d
```

版本号为示例，请按实际发行和安装情况替换。下载只来自 [llama.cpp 官方发行](https://github.com/ggml-org/llama.cpp/releases)，优先使用系统自带的 `curl.exe`（显示进度条，断线自动重试并续传），没有时回退到 `Invoke-WebRequest`。安装会检查包大小、官方 SHA256 摘要和 `llama-server --version`，成功后才保存为完整安装。缺少 SHA256 摘要的发行包会被拒绝。

CUDA 安装同时下载同一发行版的 `llama-...-bin-win-cuda-12.4-x64.zip` 与 `cudart-llama...-bin-win-cuda-12.4-x64.zip`，分别校验后将依赖 DLL 部署到程序旁边，完整依赖文件另保留在 `cuda-dependencies/`。两包均成功后才切换，依赖来源和摘要也写入 `install.json`。`Check -b cuda` 会显示两个包及其大小；CUDA 下载明显大于 CPU/Vulkan。当前不提供 CUDA 13.x 或 ARM64 版本选择。

`latest` 指最近提供对应 Windows x64 包的 build，可能包含预发布；脚本读取发行列表，而不依赖可能没有程序包的 `/releases/latest`。

数据目录（默认即脚本文件夹，见“本机配置与迁移”）的布局：

```text
llama-versions/
  vulkan/
    current.txt         默认版本编号
    b12142/
      install.json      来源、校验值、安装时间、版本输出
      llama-server.exe
      llama-cli.exe
  openvino/  cpu/  cuda/   结构相同
llama-vulkan/           可选的原始安装，称为 legacy
llama-openvino/  llama-cpu/  llama-cuda/   同上
models/                 默认模型文件夹
ov-venv/                可选的 GenAI 虚拟环境
```

启动器优先使用显式 `-v`，否则读取 `current.txt`，没有指针时回退到 `legacy`。**新克隆的仓库没有 legacy，请先安装运行时。** `Install` 不切换，安装后需 `Use` 或通过启动参数 `-v` 选择。

切换仅影响下次启动，不会停止或重启现有服务。删除前应停止该版本进程；脚本拒绝删除当前默认版本、检测到正在运行的版本、包含目录链接的版本和 `legacy`。遇到文件占用可能部分删除失败，释放占用后重试。版本管理不修改模型、NPU 驱动或 GenAI 虚拟环境。

## 帮助与参数

```powershell
.\start-llama.bat -h
.\manage-llama.bat -h
.\shortcuts\start-npu.bat -h
```

| 简写 | 完整参数 | 适用范围 |
|---|---|---|
| `-h` | `-Help` | 所有入口 |
| `-m` | `-Model` | 启动器；模型路径也可直接作为首参数 |
| `-b` | `-Backend` | 启动器：Auto/CUDA/Vulkan(iGPU)/CPU/NPU(OpenVINO)；管理器：vulkan/openvino/cpu/cuda |
| | `-Mode` | 启动器：Server（默认）或 Chat |
| `-v` | `-Version` | 管理器、GGUF 启动器 |
| `-p` | `-Port` | 启动器（服务器模式） |
| `-c` | `-Ctx` | GGUF 上下文大小 |
| `-addr` | `-HostAddr` | 绑定地址，默认 127.0.0.1 |
| `-d` | `-DryRun` | 启动器预览；管理器仅 Remove |
| `-ap` | `-AutoPort` | 自动找端口；`start-llama.bat`、`start-gguf.bat` 和拖入时默认启用 |
| `-pt` | `-PortAttempts` | 自动端口最大尝试数，默认 200 |
| `-x` | `-ExtraArgs` | llama 原生参数，需通过 `.ps1` 传数组 |
| `-a` | `-Action` | 版本管理；命令也可直接作为首参数 |
| `-mp` / `-mr` | `-MaxPrompt` / `-MaxResponse` | GenAI 静态长度限制 |

`.bat` 会在结束时暂停，便于查看错误。自动化调用可直接使用 `tools/` 里的 `.ps1`，它们不暂停、不提问（除非加 `-Ask`）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\manage-llama.ps1 List

# 在允许执行脚本的 PowerShell 会话中，直接传入数组
.\tools\start-llama.ps1 "E:\模型\model.gguf" -b CUDA -x @('--temp','0.7')
```

## 仓库内容与发布

```text
start-llama.bat               运行模型的统一入口
manage-llama.bat              运行时版本管理入口
launcher.config.example.json  本机配置模板
shortcuts/                    固定后端的快捷入口（可双击/拖入）
tools/
  start-llama.ps1             统一启动器：后端、服务器/对话模式、自动端口
  start-npu.ps1               NPU 模型别名与 OpenVINO GenAI
  manage-llama.ps1            版本管理
  llama-runtime.ps1           共享层：配置、后端注册表、版本解析、选择菜单
  llama-port.ps1              端口探测和绑定错误识别
  ov_server.py                可选 GenAI HTTP 服务
tests/test-backends.ps1       离线集成测试
```

后端的发行包匹配规则、启动参数、环境变量和默认上下文都集中在 `tools/llama-runtime.ps1` 的注册表里；新增后端或更换 CUDA 版本只需改这一处。

离线集成测试（Windows PowerShell 5.1，无需 GPU 或下载模型）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test-backends.ps1
```

测试用小型模拟发行包验证安装、依赖部署、各后端与模式的启动参数、选择菜单、配置文件与数据目录迁移和 SHA256 失败回退，不替代真实硬件上的推理测试。推送到 GitHub 后，`.github/workflows/test.yml` 会在 Windows 上自动运行同一测试，并检查脚本保持纯 ASCII（Windows PowerShell 5.1 按系统代码页读取无 BOM 脚本，非 ASCII 字符会在其他语言的系统上出错）。

`.gitignore` 排除了下载的运行时、模型、虚拟环境、缓存、日志和本机配置，上传时请保留这些排除项。

## 许可证

本仓库的脚本以 [MIT 许可证](LICENSE) 发布。脚本下载的第三方程序（llama.cpp、CUDA 运行库、OpenVINO 等）和模型不属于本仓库，遵循各自的许可证。
