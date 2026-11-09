#!/usr/bin/env -S /usr/bin/python3
"""ASCII 鲨鱼桌面层：GTK + gtk-layer-shell + WebKit2 跑上游原版引擎。

真·wlr layer surface，画在壁纸之上、窗口之下；WebKit 视图透明，
Omarchy 的壁纸从下面透上来。页面是 stackedlol/ascii-sharks 的构建产物，
引擎逻辑一行未动（透明化补丁见 ../transparent.patch）。

生命周期由本进程自己管：轮询 horizon-setup.conf，desktop_ocean=0 就退出。
不用 Quickshell 的 Process 托管——实测它 running=false 并不终止子进程，
会留下幽灵窗口。启动由 setup.sh ensure-desktop 幂等拉起，已有实例则不重复。
"""

import os
import sys
import signal
import threading
import urllib.parse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# ~/.local 是解包 gtk-layer-shell 的地方；GI 需要提前知道 typelib 与 .so 位置。
HOME = Path(os.environ.get("HOME", ""))
LIB_DIR = Path(os.environ.get("HORIZON_SHARK_LIB_DIR", str(HOME / ".local/lib")))
os.environ["LD_LIBRARY_PATH"] = str(LIB_DIR) + os.pathsep + os.environ.get("LD_LIBRARY_PATH", "")
os.environ["GI_TYPELIB_PATH"] = str(LIB_DIR / "girepository-1.0") + os.pathsep + os.environ.get("GI_TYPELIB_PATH", "")
# WebKit 默认用 DMA-BUF 挂 subsurface，和 wlr layer surface 组合会让
# Hyprland 报 protocol error 71（实测）。必须在 import WebKit2 之前设。
os.environ.setdefault("WEBKIT_DISABLE_DMABUF_RENDERER", "1")

import gi  # noqa: E402

gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gtk, WebKit2, GtkLayerShell, GLib, Gdk  # noqa: E402

CONF = Path(os.environ.get(
    "HORIZON_SETUP_CONF", str(HOME / ".config/omarchy/horizon-setup.conf")))
WEB_DIR = Path(__file__).resolve().parent.parent / "web"
POLL_MS = 1000


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def serve_web():
    """ES module 在 file:// 下会被 CORS 拒绝，必须走 http。
    只绑 127.0.0.1、只服务 web/、随机端口，不对外暴露。"""
    handler = partial(QuietHandler, directory=str(WEB_DIR))
    srv = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv.server_address[1]


def read_conf():
    """纯 key=value；缺文件/缺键一律是关，与 lib/desktop.sh 的检测一致。"""
    on, sharks = False, "classic"
    try:
        for line in CONF.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            if key.strip() == "desktop_ocean":
                on = val.strip() == "1"
            elif key.strip() == "desktop_sharks":
                sharks = val.strip() or "classic"
    except FileNotFoundError:
        pass
    return on, sharks


class SharkDesktop:
    def __init__(self):
        self.port = serve_web()
        self.window = Gtk.Window(title="horizon-ocean")
        self.window.set_decorated(False)
        # 透明视窗：让壁纸从下面透上来。
        visual = self.window.get_screen().get_rgba_visual()
        if visual:
            self.window.set_visual(visual)

        GtkLayerShell.init_for_window(self.window)
        GtkLayerShell.set_namespace(self.window, "horizon-ocean")
        GtkLayerShell.set_layer(self.window, GtkLayerShell.Layer.BACKGROUND)
        GtkLayerShell.set_keyboard_mode(self.window, GtkLayerShell.KeyboardMode.NONE)
        for edge in (GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.BOTTOM,
                     GtkLayerShell.Edge.LEFT, GtkLayerShell.Edge.RIGHT):
            GtkLayerShell.set_anchor(self.window, edge, True)
        # 传 None 即清空输入形状 = 点击穿透。gtk-layer-shell 0.10 的 GIR
        # 没导出 set_input_region，改用 GTK 自己的 input shape。
        self.window.input_shape_combine_region(None)

        self.view = WebKit2.WebView()
        self.view.set_background_color(Gdk.RGBA(0, 0, 0, 0))
        settings = self.view.get_settings()
        settings.set_property("enable-developer-extras", False)
        settings.set_property("enable-accelerated-2d-canvas", True)
        self.window.add(self.view)
        self.window.show_all()

        self.sharks = None
        self.tick()
        GLib.timeout_add(POLL_MS, self.tick)

    def url(self, sharks):
        return ("http://127.0.0.1:%d/index.html?" % self.port
                + urllib.parse.urlencode({"sharks": sharks}))

    def tick(self):
        on, sharks = read_conf()
        if not on:
            # 关掉时整进程退出，不留幽灵 layer，零 CPU。
            Gtk.main_quit()
            return False
        # 阵容变了才重载：URL 查询参数只在页面加载时读一次。
        if sharks != self.sharks:
            self.sharks = sharks
            self.view.load_uri(self.url(sharks))
        return True


def main():
    signal.signal(signal.SIGTERM, lambda *_: Gtk.main_quit())
    SharkDesktop()
    Gtk.main()


if __name__ == "__main__":
    sys.exit(main())
