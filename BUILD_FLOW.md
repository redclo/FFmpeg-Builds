# FFmpeg-Builds 构建原理与流程

## 1. 总体思路

这个仓库的核心不是“直接用一个 Dockerfile 编 FFmpeg”，而是把整个构建过程拆成两层：

1. 先构建一个包含交叉编译工具链和所有第三方依赖的 Docker 镜像。
2. 再用这个镜像去编译 FFmpeg 本体，并把结果打包成发布产物。

对应到仓库入口脚本，就是：

```text
makeimage.sh
  -> base 镜像
  -> target base 镜像
  -> 依赖源码预下载缓存
  -> 动态生成最终 Dockerfile
  -> 构建完整依赖镜像

build.sh
  -> 在完整依赖镜像里配置/编译/安装 FFmpeg
  -> 按 target/variant 规则打包产物
```

这套设计的目标是：

- 把工具链、依赖库、FFmpeg 本体三个层次分离，减少重复编译。
- 让不同目标平台共用统一的 stage 机制。
- 让依赖开关、GPL/LGPL/Nonfree 变体、不同 FFmpeg 分支都能通过脚本组合完成。

## 2. 目录职责

### 根目录入口

- `makeimage.sh`
  负责构建基础镜像、目标镜像、生成最终 Dockerfile，并产出最终构建镜像。
- `build.sh`
  负责在最终构建镜像中编译 FFmpeg，并将结果打包到 `artifacts/`。
- `download.sh`
  负责预拉取每个 stage 需要的源码或第三方包，放到 `.cache/downloads/`。
- `generate.sh`
  负责解析依赖关系并动态生成最终 `Dockerfile`。

### 构建规则

- `images/base/`
  定义所有目标共用的基础构建环境，比如编译器、cmake、meson、rust、nodejs 等。
- `images/base-*/`
  定义各 target 的专用环境，比如 `win64` 的 mingw 工具链、`linux64` 的交叉 glibc 工具链等。
- `variants/`
  定义构建目标和许可变体，如 `win64-gpl.sh`、`linux64-lgpl.sh`。
- `addins/`
  定义可叠加选项，如 `7.1`、`debug`、`lto`。
- `scripts.d/`
  每个脚本或脚本目录代表一个依赖 stage，例如 `zlib`、`x264`、`libjxl`。
- `util/`
  放通用函数、下载逻辑、stage 执行器等。

### 缓存与产物

- `.cache/downloads/`
  存放 stage 源码下载缓存。
- `artifacts/`
  存放最终打包结果。

## 3. 参数模型

仓库的命令行参数是三段式：

```bash
./makeimage.sh <target> <variant> [addin...]
./build.sh <target> <variant> [addin...]
```

### target

决定目标平台和工具链，例如：

- `win64`
- `win32`
- `linux64`
- `linuxarm64`

### variant

决定许可范围和链接方式，例如：

- `gpl`
- `lgpl`
- `nonfree`
- `gpl-shared`
- `lgpl-shared`
- `nonfree-shared`

### addin

在 variant 之上追加附加行为，例如：

- `7.1` 把 FFmpeg 分支切到 `release/7.1`
- `debug` 打开调试构建
- `lto` 开启 LTO

`util/vars.sh` 会把这些参数统一解析成：

- `TARGET`
- `VARIANT`
- `ADDINS`
- `BASE_IMAGE`
- `TARGET_IMAGE`
- `IMAGE`

因此整个仓库的后续脚本都围绕这些变量工作。

## 4. 镜像构建原理

### 4.1 base 镜像

`images/base/Dockerfile` 提供所有平台通用的构建底座，主要包括：

- Ubuntu 基础系统
- 编译工具链和常用构建工具
- cmake、meson、ninja、autotools
- rust/cargo、nodejs
- 若干仓库自带辅助脚本

当前工作树中，这个基础镜像还额外做了两件事：

- 默认把 Ubuntu apt 源切到国内镜像。
- 复制 shell 脚本时会先把 `CRLF` 转成 `LF`，避免 Windows 工作区换行问题。

### 4.2 target base 镜像

`images/base-<target>/Dockerfile` 在 base 镜像之上进一步安装目标专用工具链，例如：

- `win64` 通过 crosstool-NG 生成 `x86_64-w64-mingw32`
- `win32` 生成 `i686-w64-mingw32`
- `linux64` 生成固定 glibc 兼容范围的交叉工具链

这些镜像会统一导出一组环境变量，供后续所有 stage 使用，例如：

- `FFBUILD_TOOLCHAIN`
- `FFBUILD_TARGET_FLAGS`
- `FFBUILD_PREFIX`
- `FFBUILD_DESTDIR`
- `CC` / `CXX` / `AR` / `RANLIB`

可以把它理解成“所有依赖库和 FFmpeg 本体都会在这个约定好的交叉环境里构建”。

### 4.3 makeimage.sh 的职责

`makeimage.sh` 的执行顺序是：

1. 解析 `target/variant/addins`
2. 创建 `docker buildx` builder
3. 构建通用 base 镜像
4. 构建 target base 镜像
5. 运行 `download.sh` 预下载各 stage 源码
6. 运行 `generate.sh` 生成最终 `Dockerfile`
7. 用 `docker buildx build` 构建最终依赖镜像

当前工作树里，`makeimage.sh` 还做了两项本地增强：

- 基础镜像构建时会传入 `UBUNTU_MIRROR` 等 apt 镜像参数。
- 镜像直接构建进本地 Docker daemon，不再通过 `buildx --load` 从外部 builder 回灌。

## 5. 依赖 stage 的组织方式

### 5.1 每个依赖就是一个 stage 脚本

`scripts.d/` 里的每个脚本都实现同一套约定接口。最常见的函数有：

- `ffbuild_enabled`
  判断当前 target/variant/addin 下这个依赖是否启用。
- `ffbuild_depends`
  声明该依赖依赖哪些前置 stage。
- `ffbuild_dockerdl`
  描述如何下载该依赖源码。
- `ffbuild_dockerbuild`
  描述如何编译并安装该依赖。
- `ffbuild_configure`
  返回 FFmpeg `./configure` 需要追加的开关。
- `ffbuild_cflags` / `ffbuild_ldflags` / `ffbuild_libs`
  返回额外编译或链接参数。

例如：

- `scripts.d/20-zlib.sh`
  始终启用，编译 zlib，并向 FFmpeg 注入 `--enable-zlib`
- `scripts.d/50-x264.sh`
  在 `lgpl*` 变体下禁用，在 `gpl/nonfree` 下启用，并向 FFmpeg 注入 `--enable-libx264`

### 5.2 stage 目录表示多子阶段

如果某个依赖比较复杂，会用目录表示一个“依赖组”，例如：

- `scripts.d/45-fonts/`
- `scripts.d/47-vulkan/`
- `scripts.d/50-libjxl/`
- `scripts.d/50-vaapi/`

目录里的多个 `*.sh` 会按顺序逐个执行，形成这个依赖的多个子阶段。

### 5.3 zz-final.sh 是依赖图根节点

`scripts.d/zz-final.sh` 本身不编译任何库，它的作用是：

- 作为整个依赖图的根节点
- 列出最终 FFmpeg 构建需要合并的全部依赖

`generate.sh` 会从这个脚本出发递归分析依赖关系，因此它相当于“最终构建清单”。

## 6. 动态生成 Dockerfile 的原理

`generate.sh` 是整个仓库里最核心的调度器。

### 6.1 它不是读取固定顺序，而是解析依赖图

核心流程是：

1. 载入 `variants/<target>-<variant>.sh`
2. 载入所有 addin
3. 从 `zz-final.sh` 开始递归读取 `ffbuild_depends`
4. 找出当前依赖图中“已满足前置条件”的 stage
5. 按阶段生成 Dockerfile

这意味着：

- 依赖顺序由脚本声明驱动，不是手工硬编码一条长流水线。
- 增加一个新库时，只要实现约定函数并声明依赖，生成器就能把它接入流程。

### 6.2 生成出的 Dockerfile 分三类层

#### base-layer

来自 `base-<target>` 镜像，是所有后续 stage 的共同基底。

#### 各依赖 stage

每个依赖会生成一个独立 stage，例如：

```dockerfile
FROM <base-layer> AS x264
...
RUN --mount=src=scripts.d/50-x264.sh,dst=/stage.sh run_stage /stage.sh
```

其作用是：

- 下载源码缓存
- 编译依赖
- 安装到约定前缀

#### combine-layer 与最终层

依赖编完后，`generate.sh` 还会额外生成：

- `combine-layer`
  用于把所有依赖产物汇总到一个统一前缀。
- 最终镜像层
  把 `FF_CONFIGURE`、`FF_CFLAGS`、`FF_LDFLAGS` 等环境变量写入镜像，供 `build.sh` 直接使用。

## 7. 下载缓存机制

`download.sh` 会提前遍历 `scripts.d/*.sh` 和 `scripts.d/*/*.sh`，为每个 stage 生成一个临时下载脚本。

下载机制的关键点是：

- 每个 stage 通过 `ffbuild_dockerdl` 返回“如何下载源码”的命令串。
- 这个命令串会被哈希，得到唯一缓存键。
- 最终缓存文件写成：

```text
.cache/downloads/<stage>_<hash>.tar.xz
```

这样做的好处是：

- 同一 stage 下载命令未变化时可以直接复用缓存。
- stage 下载内容变了，缓存键自然失效。
- Dockerfile 真正执行构建时可以直接 `--mount` 这个缓存包，减少重复拉源码。

## 8. run_stage.sh 的作用

`util/run_stage.sh` 是每个依赖 stage 的统一执行器。

它负责：

- 应用阶段级的 `CFLAGS/CXXFLAGS/LDFLAGS`
- 恢复下载缓存到工作目录
- `source` 当前 stage 脚本
- 执行 `ffbuild_dockerbuild`
- 把 `DESTDIR` 中已安装内容硬链接复制回镜像根文件系统，供后续 stage 复用

当前工作树中，`run_stage.sh` 在执行 stage 脚本前会先去掉 `\r`，这是为了避免 Windows 工作区把脚本签出成 `CRLF` 后，容器里 `source` 失败。

## 9. FFmpeg 本体的构建流程

当 `makeimage.sh` 成功后，`build.sh` 会负责真正编译 FFmpeg。

其逻辑可以概括为：

1. 解析 `target/variant/addins`
2. 载入 variant 和 addin，得到 `FF_CONFIGURE` 等基础参数
3. 生成一个临时 `/build.sh`
4. 运行最终依赖镜像，把源码目录和临时脚本挂进去
5. 在容器中执行：
   - 准备 FFmpeg 源码
   - 运行 `./configure`
   - `make -j$(nproc)`
   - `make install install-doc`
6. 把安装结果从 `ffbuild/prefix` 按 variant 规则打包

在当前工作树中，`build.sh` 不是总从远端克隆 FFmpeg，而是：

- 优先使用本地目录 `/d/longhang/ffmpeg-n8.0.1`
- 以只读方式挂载到容器里的 `/ffmpeg-src`
- 如果本地目录不存在，再回退到 `git clone`

因此，这个工作树当前更像“本地 FFmpeg 源码 + 统一依赖镜像”的构建模式。

## 10. variant 和 addin 如何影响最终结果

### variant

variant 脚本通常由两部分组成：

- 一个安装/打包规则脚本
- 一个默认开关脚本

以 `variants/win64-gpl.sh` 为例，它会：

- 引入 `windows-install-static.sh`
- 引入 `defaults-gpl.sh`

因此最终同时决定：

- FFmpeg 默认 configure 选项
- 最终产物的目录结构和打包内容

例如：

- `defaults-gpl.sh`
  默认加上 `--enable-gpl --enable-version3 --disable-debug`
- `defaults-gpl-shared.sh`
  再叠加 `--enable-shared --disable-static`

### addin

addin 会进一步覆盖全局变量或向 Dockerfile 注入额外环境。

例如：

- `addins/7.1.sh`
  把 `GIT_BRANCH` 改为 `release/7.1`
- `addins/debug.sh`
  去掉 `--disable-debug`，改成 `--optflags='-Og' --disable-stripping`
- `addins/lto.sh`
  打开 `--enable-lto`，并修改编译器/归档器相关参数

## 11. 最终打包流程

`build.sh` 调用 `package_variant` 负责打包。

不同平台和链接方式打包的内容不同：

- Windows static
  主要打包 `bin/`、文档、preset
- Windows shared
  额外打包 `.dll`、`.lib`、`.def`、`pkgconfig`、头文件
- Linux static
  额外包含 man 页面

最终输出规则：

- Windows: `artifacts/*.zip`
- Linux: `artifacts/*.tar.xz`

产物名中会带上：

- FFmpeg 版本
- target
- variant
- addin 组合

## 12. 一次完整构建的实际顺序

以 `win64 gpl` 为例，实际顺序可以理解为：

```text
./makeimage.sh win64 gpl
  -> 构建 base
  -> 构建 base-win64
  -> 下载 zlib/x264/... 源码缓存
  -> 解析 zz-final.sh 依赖图
  -> 生成最终 Dockerfile
  -> 构建 ghcr.io/.../win64-gpl:latest

./build.sh win64 gpl
  -> 启动上一步生成的镜像
  -> 准备 FFmpeg 源码
  -> 运行 ./configure
  -> make && make install
  -> 打包到 artifacts/
```

## 13. 当前工作树里值得注意的定制点

这份仓库当前不是完全原版，有几处与“上游默认行为”不同的本地定制，排查问题时需要注意：

- `build.sh` 优先使用本地 FFmpeg 源码目录 `/d/longhang/ffmpeg-n8.0.1`
- `makeimage.sh` 和 `images/base/Dockerfile` 默认使用国内 Ubuntu 镜像源
- 若 stage 脚本或 `ct-ng-config` 来自 Windows 工作区，构建过程中会自动去掉 `CRLF`
- `.gitattributes` 已约束 `*.sh`、`Dockerfile`、`ct-ng-config` 等文本文件默认使用 `LF`

## 14. 结论

这个仓库的本质可以概括成一句话：

> 用脚本描述依赖、用 `generate.sh` 组装依赖图、用 Docker 多阶段构建固化工具链和第三方库、最后再在统一环境里编译并打包 FFmpeg。

它的优势不是“脚本少”，而是“模块化强”：

- 新增依赖时，只要加一个 stage 脚本并声明依赖即可。
- 切换平台时，主要换的是 target base 镜像和少量条件逻辑。
- 切换许可证、共享库/静态库、分支版本时，不需要重写主流程，只要组合 variant/addin。

## 15. Implementation Note

Current `makeimage.sh` uses local `docker build` with `DOCKER_BUILDKIT=1` for base, target, and final image builds.
It relies on local Docker image tags such as `ghcr.io/.../base:latest` and `ghcr.io/.../base-win64:latest`, instead of passing `oci-layout://...` build contexts.
This avoids both `buildx --load` export/session timeouts and the default builder's lack of support for `oci-layout` contexts.
