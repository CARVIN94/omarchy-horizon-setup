#!/usr/bin/env python3
"""第三方 Omarchy 插件显示文案汉化的幂等应用器。

映射表（maps/<id>.json）里每条是 *带上下文的完整字面量片段*（如
`text: "Busiest"`），不是裸单词——防止误伤标识符/键名/存档值。每条带
期望次数 count，应用前先数一遍：对不上就整体中止（fail-closed），
绝不半应用。

用法：
  apply-zh.py check  <map.json>   # 只校验：未汉化/已汉化/失配
  apply-zh.py apply  <map.json>   # 应用（已汉化=幂等跳过）
  apply-zh.py revert <map.json>   # 逆向还原（生成补丁/git diff 之外的恢复手段）

check 输出单行状态：state=clean|applied|mismatch 带计数，供面板解析。

随插件分发，权威副本在此（lib/apply-zh.py + lib/zh-maps/*.json）；
旧的外部共享资产目录已整体废弃，不要再从那里读取或复制。
"""

import json
import sys
from pathlib import Path

APPLIED, CLEAN, MISMATCH = "applied", "clean", "mismatch"


def load_map(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    root = Path(data["root"]).expanduser()
    if not root.is_dir():
        raise SystemExit(f"map root missing: {root}")
    return root, data


def state_of(text, rep):
    """未应用= find 全在且 replace 全不在；已应用= 反之；否则失配。"""
    f, r, n = rep["find"], rep["replace"], rep["count"]
    fc, rc = text.count(f), text.count(r)
    if fc == n and rc == 0:
        return CLEAN
    if fc == 0 and rc == n:
        return APPLIED
    return MISMATCH


def run(mode, map_path):
    root, data = load_map(map_path)
    # 预检：所有条目先判定。check 只汇报（含 mismatch 计数，供面板显示）；
    # apply/revert 遇 mismatch 立即整体拒绝（fail-closed），绝不半应用。
    plan = {}
    mismatches = []
    for rep in data["replacements"]:
        fp = root / rep["file"]
        if not fp.is_file():
            raise SystemExit(f"missing file: {fp}")
        text = fp.read_text(encoding="utf-8")
        st = state_of(text, rep)
        if st == MISMATCH:
            mismatches.append(f"{rep['file']}: find x{text.count(rep['find'])} "
                              f"replace x{text.count(rep['replace'])} expected {rep['count']} :: {rep['find'][:60]}")
        plan.setdefault(fp, (text, []))[1].append((st, rep))

    if mode == "check":
        counts = {APPLIED: 0, CLEAN: 0, MISMATCH: 0}
        for reps in plan.values():
            for st, _ in reps[1]:
                counts[st] += 1
        if counts[MISMATCH] > 0:
            state = MISMATCH
        else:
            state = APPLIED if counts[CLEAN] == 0 else CLEAN
        print(f"state={state} applied={counts[APPLIED]} clean={counts[CLEAN]} "
              f"mismatch={counts[MISMATCH]} total={len(data['replacements'])}")
        for line in mismatches:
            print(f"mismatch-detail {line}")
        return 0 if counts[MISMATCH] == 0 else 1

    if mismatches:
        raise SystemExit("MISMATCH, refusing to touch anything:\n  " + "\n  ".join(mismatches))

    if mode == "apply":
        for fp, (text, reps) in plan.items():
            for st, rep in reps:
                if st == CLEAN:
                    text = text.replace(rep["find"], rep["replace"])
            fp.write_text(text, encoding="utf-8")
        print(f"applied {len(data['replacements'])} replacements -> {root}")
        return 0

    if mode == "revert":
        for fp, (text, reps) in plan.items():
            for st, rep in reps:
                if st == APPLIED:
                    text = text.replace(rep["replace"], rep["find"])
            fp.write_text(text, encoding="utf-8")
        print(f"reverted {len(data['replacements'])} replacements -> {root}")
        return 0

    raise SystemExit(f"unknown mode: {mode}")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("check", "apply", "revert"):
        raise SystemExit(__doc__)
    sys.exit(run(sys.argv[1], sys.argv[2]))
