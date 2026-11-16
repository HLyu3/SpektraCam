# Spektra Cam

**Spektra Cam 是 [SpektraLab](https://github.com/JamesQiu2005/SpektraLab)（Mac 上的胶片冲洗软件）的非官方 iPhone 移植版。** 用的是同一个胶片物理引擎——胶片曝光、染料层、颗粒、光晕、放大机与相纸，一路算下来，而不是给照片套一张 LUT——并在 iPhone 上加了相机、观片台等功能。

> 非官方：不是 SpektraLab 作者发布的 App。
> 胶片引擎来自 [JamesQiu2005/SpektraLab](https://github.com/JamesQiu2005/SpektraLab)（本版用 2.4.0 引擎）；
> 起点是它的 iOS 社区移植版 [Minerchu/SpektraLab-iOS](https://github.com/Minerchu/SpektraLab-iOS) 1.2.0，之后界面重做、功能大幅扩展。

## 下载与安装

到 **[Releases](../../releases/latest)** 下载 `SpektraCam-2.0.0-unsigned.ipa`。IPA 没有签名，需要用自己的 Apple ID 重签：

| 工具 | 做法 |
|---|---|
| Sideloadly / AltStore / SideStore | 选这个 IPA，用自己的 Apple ID 签名安装 |
| Xcode | 按下面“本地构建”编译，在 Signing 里选自己的 Personal Team |

- 最低系统 **iOS 27.0**，只支持 iPhone。
- **目前只在 iPhone 17 Pro Max（iOS 27）上测试过。** 其他机型能装，但镜头焦段、拍摄尺寸、导出内存上限和 HDR 亮度没有验证过，可能有问题。
- 免费 Apple ID 的签名 7 天后过期，要重新安装。
- IPA 里带了全部引擎资源，第一次打开不需要联网下载。

## 2.0.0：相对社区移植版 1.2.0 的变化

**界面：暗房**
- 新名字、新图标；全新配色（石墨黑、相纸白、安全灯琥珀色）、胶片颗粒背景。
- 底栏三处：**底片**（图库）· **拍摄** · **观片台**。

**底片（图库）**
- 一排点一下就切换的筛选（拍摄 / 导入 / 收藏 / 已调色 / RAW / 双拼 / 胶片），按拍摄时间、添加时间或胶片排序。
- 按天分组；像系统相册一样双指缩放，每行 1–14 张，缩远了按月分组。
- 直接读系统相册（不复制），或导入到 App 里；从“文件”、存储卡（读卡器，整个 DCIM 文件夹）、其他 App 导入，RAW + JPEG 只留 RAW，导入过的自动跳过。
- 挑片：没导出的拍摄按天列出，留下的导出、其余删除；底片保留期可设。
- 配方库：存配方、收藏胶片，一键套到多张照片。

**编辑**
- 按光路排的工具：取景 · 镜头 · 曝光 · 胶片 · 相纸 · 后期。
- 裁剪与拉直、全局撤销 / 重做、长按看原图。
- 解码曲线、黑白胶片（Tri-X、T-Max 100、Acros II、HP5，配 Multigrade 相纸 00–5 号）、去防光晕层、漏光、柔光镜、镜头风格（漩涡、Petzval、老镜头、玩具镜头）。
- 后期（Layer 2）：光线、色彩、HSL、曲线、色彩平衡。
- **HDR**：引擎按胶片与相纸的肩部算出每个像素的增益，编辑画面在 HDR 屏幕上亮过白色；导出 JPEG / HEIF 时附 ISO 增益图。
- 半格双拼：两张拼成一张半格胶片。
- 导出：JPEG / 10-bit HEIF / 16-bit TIFF / PNG，sRGB / Display P3 / Adobe RGB / ProPhoto，按内存自动限制尺寸，48 MP 可全尺寸导出。

**拍摄**
- ProRAW、单帧 RAW（不做多帧合成与降噪）、HEIF；按镜头列出真实尺寸。
- 焦段 13 / 24 / 48 / 100 / 200 mm（48 和 200 是传感器内裁切），双指变焦。
- 取景器实时显示胶片色彩（引擎烘出的 3D LUT）；手动快门、ISO、曝光补偿、色温；水平仪、网格、直方图。
- 胶卷可以是一种胶片、一个配方，或“无胶卷”（原始文件直接进“照片”）；拍完可自动在后台冲洗。

**观片台**
- 把照片按真实毫米尺寸摆在 A4 / A5 / A6 灯箱上，拖动、旋转、整理、打乱。
- EDR 背光、开关灯、放大镜（2–8×，按住不动凑近）、全屏幻灯。

工程、目标和内部代码仍沿用 `SpektraLab` 这个名字（`ios/SpektraLab.xcodeproj`），只有 App 显示为 Spektra Cam。

## 本地构建

需要 Apple silicon Mac、Xcode 27.2+、iOS 27 SDK、Python 3.10+。

```bash
git clone <本仓库地址>
cd SpektraCam

# 引擎：上游 2.4.0
GITHUB_TOKEN="<你的 GitHub Token>" python3 tools/fetch-engine.py \
  JamesQiu2005/SpektraLab 87de3b6c837f9e21ad67924c50b169b3bacbfc5e .
# 2.4.0 去掉了胶片封面图：从上一个引擎版本取回 engine/resources_product/film_covers
GITHUB_TOKEN="<你的 GitHub Token>" python3 tools/fetch-engine.py \
  JamesQiu2005/SpektraLab 02d82b56cf65f0f8e802a708612edc4e9a4790af /tmp/engine-1.3.5
cp -R /tmp/engine-1.3.5/engine/resources_product/film_covers engine/resources_product/
python3 tools/apply-ios-patch.py engine      # 只能在刚取下的引擎上跑一次

bash engine/setup-libraw.sh                  # LibRaw 0.22.2
ios/Tools/build-engine.sh bundle device      # 必须在生成工程之前

SPEKTRAFILM_BUNDLE_ID=<你的 bundle id> SPEKTRAFILM_SIGNING_STYLE=Automatic \
SPEKTRAFILM_SIGN_IDENTITY="Apple Development" SPEKTRAFILM_TEAM_ID=<你的 Team ID> \
  python3 ios/Tools/gen-project.py
open ios/SpektraLab.xcodeproj
```

`ios/Tools/build-engine.sh bundle device` 要在 `gen-project.py` 之前运行，否则工程里没有 `engine-assets.bin`，App 会一直显示“引擎还在准备”。

免费账号也能用 `com.apple.developer.kernel.increased-memory-limit`（已写在 entitlements 里），48 MP 全尺寸导出需要它。

## 已知限制

- 只在 iPhone 17 Pro Max 上测试过（见“下载与安装”）。

- 只支持 iPhone；没有 iPad 布局。
- 没有视频。
- 反转片的 HDR 还没做（需要引擎的第二次渲染）；HDR 增益图最长 2048 px。
- 观片台用照片的冲洗缩略图（900 px），放大到 6 倍以上会软。
- “照片”App 的分享菜单里没有本 App（没有分享扩展）；从“文件”和其他 App 可以传入。
- `.github/workflows/build-ios.yml` 是社区版原样保留的 CI：它固定在旧引擎、要用社区版的签名密钥，构建不了这个版本；fork 仓库默认不运行 Actions，请不要启用它。本版的 IPA 是在本地构建的。

## 许可与致谢

- 核心引擎与胶片过程模型：[JamesQiu2005/SpektraLab](https://github.com/JamesQiu2005/SpektraLab)，GPL-3.0-or-later。
- 起点代码：iOS 社区移植版 [Minerchu/SpektraLab-iOS](https://github.com/Minerchu/SpektraLab-iOS)，GPL-3.0-or-later。
- 胶片模型、实测配置与放大 LUT：[Andrea Volpato/spektrafilm](https://github.com/andreavolpato/spektrafilm)，CC BY-SA 4.0。
- RAW 回退解码：[LibRaw](https://github.com/LibRaw/LibRaw) 0.22.2，LGPL-2.1 / CDDL-1.0。

Spektra Cam 的代码按 **GPL-3.0-or-later** 分发；胶片与相纸配置按 **CC BY-SA 4.0** 分发。胶片、相纸的名称和商标归各自权利人所有。
