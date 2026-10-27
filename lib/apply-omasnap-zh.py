#!/usr/bin/env python3
"""把 Omasnap 源码里的界面文案换成译文。

上游没有任何 i18n 设施：UI 文案是硬编码的 C++ 字符串字面量，有两种形态：
  1. QStringLiteral("...")，常常是多行相邻字面量拼接 —— 按词法位置整串替换
  2. const char* 数组里的显示标签（如区域比例的 "Free"）—— 按带上下文的
     完整代码片段替换（裸替换一个 "Free" 会误伤别处）

为什么不打 git patch：patch 的行号与上下文一碰上游更新就废，多行拼接也会被
reflow 打断。上游一旦改文案，该条目未命中 → 编译前整体拒绝，不猜、不半应用。

用法：
  apply-omasnap-zh.py --table zh.json --root <源码目录> [--dry-run]
退出码：0 = 全部命中；1 = 有条目没命中（上游文案变了）。
"""

import argparse
import json
import re
import sys
from pathlib import Path

SUFFIXES = (".cpp", ".hpp")
ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'"}


def unescape(body: str) -> str:
    out, i = [], 0
    while i < len(body):
        ch = body[i]
        if ch == "\\" and i + 1 < len(body):
            nxt = body[i + 1]
            if nxt in ESCAPES:
                out.append(ESCAPES[nxt])
                i += 2
                continue
            if nxt == "u" and i + 5 < len(body):
                out.append(chr(int(body[i + 2:i + 6], 16)))
                i += 6
                continue
        out.append(ch)
        i += 1
    return "".join(out)


def escape(text: str) -> str:
    return (text.replace("\\", "\\\\").replace('"', '\\"')
            .replace("\n", "\\n").replace("\t", "\\t"))


def read_literal(text: str, i: int):
    """从 text[i] 的引号读到收尾引号，返回 (逻辑串, 结束下标)。"""
    assert text[i] == '"'
    i += 1
    buf = []
    while i < len(text):
        if text[i] == "\\":
            buf.append(text[i:i + 2])
            i += 2
            continue
        if text[i] == '"':
            return unescape("".join(buf)), i + 1
        buf.append(text[i])
        i += 1
    return None, i


def skip_space_and_comments(text: str, i: int) -> int:
    while i < len(text):
        if text[i] in " \t\r\n":
            i += 1
            continue
        if text.startswith("//", i):
            nl = text.find("\n", i)
            i = len(text) if nl < 0 else nl + 1
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = len(text) if end < 0 else end + 2
            continue
        break
    return i


def adjacent_literals(text: str, i: int):
    """从 i 起收集所有相邻字面量，返回 (逻辑串, 结束下标) 或 (None, i)。"""
    parts = []
    i = skip_space_and_comments(text, i)
    while i < len(text) and text[i] == '"':
        raw, i = read_literal(text, i)
        if raw is None:
            return None, i
        parts.append(raw)
        i = skip_space_and_comments(text, i)
    if not parts:
        return None, i
    return "".join(parts), i


def rewrite(text: str, table: dict, fragments: dict, hits: dict):
    """改写一段源码，返回 (新文本, 替换次数)。"""
    # 1) 带上下文的裸字符串：精确片段替换，先做（片段里不会含 QStringLiteral）。
    for src_frag, dst_frag in fragments.items():
        if src_frag in text:
            text = text.replace(src_frag, dst_frag)
            hits[src_frag] = hits.get(src_frag, 0) + 1

    # 2) QStringLiteral("...")，含多行拼接。
    out, pos, replaced = [], 0, 0
    for m in re.finditer(r"QStringLiteral\s*\(", text):
        if m.start() < pos:
            continue
        literal, j = adjacent_literals(text, m.end())
        if literal is None or literal not in table:
            continue
        j = skip_space_and_comments(text, j)
        if j >= len(text) or text[j] != ")":
            continue
        out.append(text[pos:m.start()])
        out.append('QStringLiteral("%s")' % escape(table[literal]))
        pos = j + 1
        replaced += 1
        hits[literal] = hits.get(literal, 0) + 1

    return "".join(out) + text[pos:], replaced


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--table", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    data = json.loads(Path(args.table).read_text(encoding="utf-8"))
    table = data.get("strings", data)
    fragments = data.get("fragments", {})
    root = Path(args.root).expanduser()
    src = root / "src"
    if not src.is_dir():
        sys.exit(f"源码目录不存在: {src}")

    hits, total = {}, 0
    for path in sorted(p for p in src.iterdir() if p.suffix in SUFFIXES):
        text = path.read_text(encoding="utf-8")
        new, n = rewrite(text, table, fragments, hits)
        if new != text:
            total += n
            if not args.dry_run:
                path.write_text(new, encoding="utf-8")

    expected = list(table) + list(fragments)
    missed = [k for k in expected if k not in hits]
    print(f"替换 {total} 处，覆盖 {len(hits)}/{len(expected)} 条")
    for key in missed:
        print(f"  未命中: {key!r}")
    if missed:
        print(f"共 {len(missed)} 条未命中（上游文案可能已变）", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
