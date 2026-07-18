#!/usr/bin/env python3
"""组装发布日志:人工亮点优先,cliff 全量明细折叠兜底。

输入(cwd,均由 build.yaml 的前序步骤生成):
- release_notes.md   cliff 全量明细(markdown,含 Full Changelog 行)
- release_notes.txt  cliff 全量明细(plain,AltStore 用)
- highlights/<tag>.md  人工撰写的用户视角亮点(可选,仅 stable 消费)

输出(cwd):
- release_notes.md        GH Release 正文源:亮点 + <details> 折叠明细 + compare 行
- release_notes_tg.md     Telegram 文本源:仅亮点 + compare 行
- release_notes.txt       AltStore 文本源:亮点纯文本化
- release_notes_detail.md 原始 cliff 明细快照(TG 脚本从中收集贡献者)

亮点文件缺失或非 stable 时,三个渠道均保持现状(全量明细)。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# 与 release_telegram.py 的 _FULL_CHANGELOG_RE 保持同构
_FULL_CHANGELOG_RE = re.compile(
    r"^\*\*Full Changelog\*\*:\s*https://\S+\s*$",
    re.MULTILINE,
)


def plainify(md: str) -> str:
    """把亮点 markdown 降为纯文本(AltStore localizedDescription 不渲染 markdown)。"""
    lines: list[str] = []
    for raw in md.splitlines():
        line = re.sub(r"^#{1,6}\s+", "", raw)
        line = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", line)
        line = line.replace("**", "")
        line = re.sub(r"`([^`]+)`", r"\1", line)
        lines.append(line)
    text = "\n".join(lines)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="本次发布 tag,如 v0.2.23")
    parser.add_argument("--stable", required=True, help="true / false")
    args = parser.parse_args()

    notes_path = Path("release_notes.md")
    tg_path = Path("release_notes_tg.md")
    plain_path = Path("release_notes.txt")
    detail_path = Path("release_notes_detail.md")

    detail_md = notes_path.read_text(encoding="utf-8")
    # 无论走哪条路径,原始明细都留一份快照(贡献者致谢从这里收集)
    detail_path.write_text(detail_md, encoding="utf-8")

    highlights_path = Path("highlights") / f"{args.tag}.md"
    is_stable = args.stable.strip().lower() == "true"

    if not is_stable or not highlights_path.exists():
        reason = "非 stable 版本" if not is_stable else f"未找到 {highlights_path}"
        print(f"{reason},保持全量明细,不做亮点组装")
        tg_path.write_text(detail_md, encoding="utf-8")
        return 0

    highlights = highlights_path.read_text(encoding="utf-8").strip()
    if not highlights:
        print(f"{highlights_path} 为空,保持全量明细")
        tg_path.write_text(detail_md, encoding="utf-8")
        return 0

    m = _FULL_CHANGELOG_RE.search(detail_md)
    compare_line = m.group(0).strip() if m else ""
    detail_body = _FULL_CHANGELOG_RE.sub("", detail_md).strip()

    # GH Release:亮点正文 + 折叠明细,compare 行放折叠块外便于直接点到
    gh_text = (
        f"{highlights}\n\n"
        "<details>\n"
        "<summary>📋 完整更新明细(点击展开)</summary>\n\n"
        f"{detail_body}\n\n"
        "</details>\n"
    )
    if compare_line:
        gh_text += f"\n{compare_line}\n"
    notes_path.write_text(gh_text, encoding="utf-8")

    # Telegram:仅亮点;compare 行保留供脚本抽成顶部链接
    tg_text = highlights + (f"\n\n{compare_line}\n" if compare_line else "\n")
    tg_path.write_text(tg_text, encoding="utf-8")

    # AltStore:亮点纯文本化(后续步骤会按段落截断到 1500 字符)
    plain_path.write_text(plainify(highlights) + "\n", encoding="utf-8")

    print(f"已用 {highlights_path} 组装发布日志(GH Release / Telegram / AltStore)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
