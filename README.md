# 阿列夫一 · 全屏黑洞 (BlackHoleScreenWarp-Aleph1)

macOS 全屏阿列夫一视觉效果 overlay —— 基于 Schwarzschild 黑洞实时渲染，将事件视界造型替换为《鸣潮》阿列夫一（Aleph-1）风格的蓝白眼状黑洞，实时扭曲当前桌面画面，并在中心向下流动的虚无物质区域叠加流光、细丝、粒子、粘液和边缘色散特效。

> **⚠️ 健康警告**  
> 虽然我们都知道阿列夫一很可爱，但请不要长时间盯着它，银白色吸积盘和其他部位的锐化和亮度较高容易损害眼睛。  
> **光敏性癫痫警告**：本程序包含快速变化的亮度、高对比度闪烁图案和动态视觉特效，可能诱发光敏性癫痫发作。如果您或您的家人有癫痫病史，请在运行前咨询医生。如在使用过程中出现头晕、视力模糊、肌肉抽搐、意识模糊或其他不适症状，请立即停止使用并闭眼休息。

## 原理

基于 Eric Bruneton 的 Schwarzschild 黑洞实时高质量渲染方法，在 Metal 片段着色器中数值积分光子测地线方程，实时计算引力透镜、光子环和吸积盘辐射。

核心移植自 [ghostty-blackhole](https://github.com/s0xDk/ghostty-blackhole)，将其从 Ghostty 终端自定义着色器迁移为 macOS 全屏 Metal overlay。

本副本额外参考了《鸣潮》Wiki 对 Aleph-1 / 阿列夫一的描述：其外观类似黑洞，但中心是向下流动的蓝色虹膜，并有白色吸积盘。因此 shader 保留黑洞透镜骨架，同时把最终合成层改为蓝白眼状虹膜、银白蓝紫吸积盘、时钟刻度光圈、星场和向下流淌的非牛顿粘液柱。

## 视觉层次

| 层 | 名称 | 说明 |
|----|------|------|
| L1 | 阿列夫一虹膜 | 黑色瞳孔（含不规则裂纹边缘）+ 电蓝色虹膜放射纤维 + 上半部橙红云纹/裂纹 + 蘑菇状蓝白爆裂冠 + 非牛顿分叉粘稠流体拖尾 + 眼球贴图（iris_plume_mask） |
| L2 | 冷色吸积盘 | Keplerian 薄盘，银白→蓝紫光谱，含多普勒束流、紫色路径、稀疏外区扰动臂 |
| L3 | 光子环刻度 | 扁平椭圆时钟刻度光圈（冷白蓝），下半部更强 |
| L4 | 星场 | 随机生成的透镜化星空 + 宇宙背景流线 |

## 依赖

- macOS 13+
- Xcode Command Line Tools（提供 Swift 和 Metal 编译器）
- 屏幕录制权限（Screen Recording permission）—— 用于捕获桌面截图作为背景纹理

## 构建

```bash
cd BlackHoleScreenWarp-Aleph1
swift build
```

## 运行

```bash
# Demo 模式：立即显示黑洞效果，持续 N 秒后退出
.build/debug/BlackHoleScreenWarp --demo --duration 16

# 手动模式：启动后在终端输入 start 触发；输入 exit 播放退出动画
.build/debug/BlackHoleScreenWarp --manual

# 工作时长触发模式：运行 N 分钟后开始出现黑洞效果
.build/debug/BlackHoleScreenWarp --delay-min 55

# 自截帧模式：在指定时间点自动保存渲染截图
.build/debug/BlackHoleScreenWarp --demo --duration 24 \
  --capture-dir ./verification/capture \
  --capture-times 7.2,11,16,22

# 查看帮助
.build/debug/BlackHoleScreenWarp --help
```

## 键盘控制

| 按键 | 功能 |
|------|------|
| `Esc` | 强制触发退出收缩动画，然后关闭程序 |

`--manual` 模式不会抢键盘焦点，也不会拦截鼠标。可靠控制方式是终端命令：输入 `start` 后回车触发，输入 `exit` 后回车播放退出动画并关闭。

## 触发与退出条件

| 模式 | 触发条件 | 退出条件 |
|------|----------|----------|
| `--demo` | 程序启动后立即触发 | 指定 `--duration N` 时，最后数秒自动播放退出动画；或按 `Esc` 强制退出 |
| `--delay-min N` | 程序运行 N 分钟后触发 | 按 `Esc` 强制播放退出动画；若指定 `--duration N`，到时自动退出 |
| `--manual` | 终端输入 `start` 手动触发 | 输入 `exit` 或按 `Esc`；未触发时直接关闭 |

## 参数说明

| 参数 | 说明 |
|------|------|
| `--demo` | 立即启动黑洞效果演示 |
| `--manual` | 启动后等待手动触发 |
| `--delay-min <N>` | 运行 N 分钟后开始出现黑洞效果 |
| `--duration <N>` | 运行 N 秒后自动退出 |
| `--capture-dir <path>` | 自截帧输出目录 |
| `--capture-times <t1,t2,...>` | 逗号分隔的截帧时间点（秒） |
| `--help, -h` | 显示帮助信息 |

## 动画时间线

| 时间 | 事件 |
|------|------|
| 0s | 黑洞吸积盘、黑色眼睑、眼球贴图同步开始渐显 |
| ~2.5s | 非牛顿粘液开始从眼球下沿流出 |
| ~3.5s | 粘液开始持续向下拉伸 |
| ~5.5s | 黑洞完全形成，眼球贴图趋于全不透明 |
| ~16s | 粘液拉伸达到最大长度 |

## 项目结构

```
BlackHoleScreenWarp-Aleph1/
├── Package.swift              # Swift Package Manager 配置
├── README.md                  # 本文件（中文）
├── README_EN.md               # English version
├── Assets/
│   └── aleph/
│       ├── iris_plume_mask.png   # 眼球虹膜/蘑菇云贴图 (512×512 RGBA)
│       └── slime_mask.png        # 粘液形状贴图 (256×512 RGBA)
├── Sources/
│   ├── main.swift                # 入口 + CLI 参数解析
│   ├── BlackHoleWindow.swift     # 全屏透明 overlay 窗口
│   └── BlackHoleRenderer.swift   # Metal 渲染器 + 内嵌 MSL Shader (~1600行)
└── verification/                 # 迭代验证截图与备份
```

## 注意事项

- 此项目为原型 demo，不安装 LaunchAgent、不加入登录项、不自动常驻后台
- 不移动、删除或修改任何真实文件
- 不上传屏幕内容，不调用远程 API
- 需要屏幕录制权限才能捕获桌面画面；若无权限则显示黑屏

## 参考与许可

- [ghostty-blackhole](https://github.com/s0xDk/ghostty-blackhole) — 原始 Schwarzschild 着色器
- [Eric Bruneton's black hole shader](https://ebruneton.github.io/black_hole_shader/) — 理论基础
- [black-hole (WebGL)](https://github.com/oseiskar/black-hole) — WebGL Schwarzschild geodesic simulation
- [Aleph-1 | Wuthering Waves Wiki](https://wutheringwaves.fandom.com/wiki/Aleph-1) — 阿列夫一外观参考
- [NASA SVS Black Hole Accretion Disk](https://svs.gsfc.nasa.gov/13326/) — 吸积盘可视化参考

本项目遵循原始 ghostty-blackhole 的许可条款。

---

*阿列夫一形象及《鸣潮》相关知识产权归 Kuro Games 所有。本项目为非商业粉丝创作，仅供学习和技术研究使用。*
