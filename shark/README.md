# ASCII 鲨鱼桌面层

桌面海洋用的是 [stackedlol/ascii-sharks](https://github.com/stackedlol/ascii-sharks)
的**原版引擎**（MIT），不是重写。上游 1500 行 TypeScript 的仿真与光栅逻辑
一行未动，这里只做接入：透明底、本地等宽字体、桌面层窗口。

## 目录

| 路径 | 内容 |
| --- | --- |
| `web/index.html` | 上游 `index.html`，去掉 Google Fonts 外链、背景改透明 |
| `web/assets/index-*.js` | `npm run build` 的产物（vite，单文件，约 30KB） |
| `transparent.patch` | 相对上游 `src/renderer.ts` 的透明化补丁（3 处） |
| `LICENSE` | 上游 MIT 许可全文 |
| `bin/shark-desktop.py` | GTK + gtk-layer-shell + WebKit2 的桌面层宿主（自带生命周期） |

## 为什么透明化要打补丁

上游把画布背景刷成纯黑（`fillStyle = "#000"` / `fillRect`）并且用
`{ alpha: false }` 建 2D 上下文。直接拿它当桌面层会把 Omarchy 的壁纸
整块盖掉。补丁只改这三行：上下文允许 alpha、背景层 `clearRect`、
每帧绘制前 `clearRect`，于是壁纸从下层透上来。仿真与 ASCII 光栅逻辑不变。

## 重建产物

上游固定在 commit（见 `UPSTREAM`）；要升级或重新构建：

```sh
git clone https://github.com/stackedlol/ascii-sharks /tmp/ascii-sharks
cd /tmp/ascii-sharks
patch -p1 < /path/to/shark/transparent.patch   # 只改 renderer.ts
# 把 index.html 的 <link ...googleapis...> 删掉、body/html 背景改 transparent
npm install && npm run build
cp -r dist/assets shark/web/
cp dist/index.html shark/web/index.html
```

## 为什么不用 Quickshell 的 QML Canvas

实测过：QML 的 JS 引擎是解释器、Canvas 是软件光栅。逐格 `fillText`
画 1600 格只有 10fps，按行批处理勉强 30fps，还引出字形方向、dpr 缩放、
主题配色一堆妥协，效果始终与原版有差距。WebKit2 跑的是 Chromium 同源的
JIT 引擎，原版代码直接跑，分辨率与帧率天然正确。
