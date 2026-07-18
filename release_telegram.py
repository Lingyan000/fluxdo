from __future__ import annotations

import json
import os
import re
import time
from html import escape as html_escape
from pathlib import Path

import requests


# === Markdown → Telegram HTML 转换 ===

_LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
_BOLD_RE = re.compile(r"\*\*([^*]+)\*\*")
_HEADING_RE = re.compile(r"^(#{1,6})\s+(.+)$", re.MULTILINE)
_INLINE_CODE_RE = re.compile(r"`([^`]+)`")


def md_to_html(md: str) -> str:
    """把 release_notes.md 渲染成 Telegram 支持的 HTML 子集（仅 b / a / code）。"""
    links: list[tuple[str, str]] = []
    codes: list[str] = []

    def _store_link(m: re.Match) -> str:
        links.append((m.group(1), m.group(2)))
        return f"\x00LINK{len(links) - 1}\x00"

    def _store_code(m: re.Match) -> str:
        codes.append(m.group(1))
        return f"\x00CODE{len(codes) - 1}\x00"

    text = _LINK_RE.sub(_store_link, md)
    text = _INLINE_CODE_RE.sub(_store_code, text)

    text = html_escape(text, quote=False)

    text = _BOLD_RE.sub(lambda m: f"<b>{html_escape(m.group(1))}</b>", text)
    text = _HEADING_RE.sub(lambda m: f"<b>{html_escape(m.group(2))}</b>", text)

    for i, (label, url) in enumerate(links):
        anchor = f'<a href="{html_escape(url, quote=True)}">{html_escape(label)}</a>'
        text = text.replace(f"\x00LINK{i}\x00", anchor)
    for i, code in enumerate(codes):
        text = text.replace(f"\x00CODE{i}\x00", f"<code>{html_escape(code)}</code>")

    return text


# === release notes 适配 TG ===

# cliff 模板给每条 commit 加的 " by @github用户名" 后缀
_AUTHOR_RE = re.compile(r"\s+by\s+@([A-Za-z0-9-]+)\s*$", re.MULTILINE)
_FULL_CHANGELOG_RE = re.compile(
    r"^\*\*Full Changelog\*\*:\s*(https://\S+/compare/(\S+)\.\.\.(\S+?))\s*$",
    re.MULTILINE,
)


def strip_authors(md: str) -> tuple[str, list[str]]:
    """去掉每条末尾的 " by @user" 并收集用户名。

    TG 会把消息里的 @xxx 自动识别为 Telegram 用户提及，可能链接到同名的
    陌生账号；由调用方决定是否以 GitHub 链接形式统一致谢。
    """
    authors: list[str] = []

    def _collect(m: re.Match) -> str:
        user = m.group(1)
        if user not in authors:
            authors.append(user)
        return ""

    return _AUTHOR_RE.sub(_collect, md), authors


def extract_compare_link(md: str) -> tuple[str, tuple[str, str, str] | None]:
    """把 "**Full Changelog**: <裸长链接>" 行抽出来，改由顶部链接行统一展示。

    返回 (去掉该行的 md, (url, 上一版 tag, 本版 tag) 或 None)。
    """
    m = _FULL_CHANGELOG_RE.search(md)
    if not m:
        return md, None
    return _FULL_CHANGELOG_RE.sub("", md), (m.group(1), m.group(2), m.group(3))


def tidy_notes(md: str) -> str:
    """notes 排版适配 TG：去掉与消息标题重复的 H2 版本行，压紧空行
    （仅分组标题前留一个），列表符号 - 换成 •。"""
    lines: list[str] = []
    for raw in md.splitlines():
        line = raw.rstrip()
        if not line or line.startswith("## "):
            continue
        if line.startswith("### "):
            if lines:
                lines.append("")
            lines.append(line)
        elif line.startswith("- "):
            lines.append("• " + line[2:])
        else:
            lines.append(line)
    return "\n".join(lines)


# === 长文本切分 ===

MESSAGE_LIMIT = 4000  # TG sendMessage 上限 4096，留余量


def split_message(text: str, limit: int = MESSAGE_LIMIT) -> list[str]:
    if len(text) <= limit:
        return [text]
    chunks: list[str] = []
    remaining = text
    while len(remaining) > limit:
        cut = remaining.rfind("\n\n", 0, limit)
        if cut == -1:
            cut = remaining.rfind("\n", 0, limit)
        if cut == -1:
            cut = limit
        chunks.append(remaining[:cut])
        remaining = remaining[cut:].lstrip("\n")
    if remaining:
        chunks.append(remaining)
    return chunks


# === 工具 ===

def chunked(items: list, n: int):
    for i in range(0, len(items), n):
        yield items[i : i + n]


def post_with_retry(url: str, *, max_retries: int = 3, **kwargs) -> requests.Response:
    last_exc: Exception | None = None
    for attempt in range(max_retries):
        try:
            resp = requests.post(url, timeout=300, **kwargs)
            if 500 <= resp.status_code < 600:
                raise requests.HTTPError(f"server {resp.status_code}: {resp.text[:200]}")
            return resp
        except (requests.ConnectionError, requests.Timeout, requests.HTTPError) as e:
            last_exc = e
            if attempt < max_retries - 1:
                wait = 2 ** (attempt + 1)
                print(f"请求失败 ({e})，{wait}s 后重试 ({attempt + 1}/{max_retries})")
                time.sleep(wait)
    raise RuntimeError(f"请求重试 {max_retries} 次仍失败: {last_exc}")


def _check_payload(resp: requests.Response, label: str) -> dict:
    try:
        payload = resp.json()
    except ValueError:
        payload = {"ok": False, "error": resp.text}
    if not payload.get("ok"):
        raise RuntimeError(f"{label} 失败: {payload}")
    return payload


# === TG API ===

def send_message(
    api_base: str, token: str, chat_id: str, html: str, sent_ids: list[int]
) -> int:
    """发主消息（可能多片）。返回第一片 message_id，作为后续 reply 的锚点。"""
    url = f"{api_base}/bot{token}/sendMessage"
    chunks = split_message(html)
    root_id: int | None = None
    for idx, chunk in enumerate(chunks):
        prefix = "" if idx == 0 else "<i>（续）</i>\n"
        data: dict = {
            "chat_id": chat_id,
            "text": prefix + chunk,
            "parse_mode": "HTML",
            "disable_web_page_preview": "true",
        }
        if root_id is not None:
            # 续段引用第一片，TG 里整个串聚合显示
            data["reply_to_message_id"] = root_id
            data["allow_sending_without_reply"] = "true"
        resp = post_with_retry(url, data=data)
        payload = _check_payload(resp, f"sendMessage chunk {idx + 1}/{len(chunks)}")
        msg_id = payload["result"]["message_id"]
        sent_ids.append(msg_id)
        if root_id is None:
            root_id = msg_id
        print(f"sendMessage chunk {idx + 1}/{len(chunks)} OK (id={msg_id})")
    assert root_id is not None
    return root_id


def send_files(
    api_base: str,
    token: str,
    chat_id: str,
    files: list[Path],
    version: str,
    sent_ids: list[int],
    reply_to: int | None = None,
) -> None:
    url = f"{api_base}/bot{token}/sendMediaGroup"
    batches = list(chunked(files, 10))
    total = len(batches)
    caption = f"FluxDO v{version} - 安装包"[:1024]

    for batch_idx, batch in enumerate(batches):
        media: list[dict] = []
        opened: dict = {}
        try:
            for idx, fp in enumerate(batch, start=1):
                key = f"file{idx}"
                media.append({"type": "document", "media": f"attach://{key}"})
                opened[key] = fp.open("rb")
            if batch_idx == total - 1:
                media[-1]["caption"] = caption
            data: dict = {"chat_id": chat_id, "media": json.dumps(media)}
            if reply_to is not None:
                # 引用主消息，TG 里显示为"文件回复说明"的串联
                data["reply_to_message_id"] = reply_to
                data["allow_sending_without_reply"] = "true"
            resp = post_with_retry(url, data=data, files=opened)
            payload = _check_payload(resp, f"sendMediaGroup 批 {batch_idx + 1}/{total}")
            sent_ids.extend(m["message_id"] for m in payload["result"])
            print(f"sendMediaGroup batch {batch_idx + 1}/{total} ({len(batch)} 个文件) OK")
        finally:
            for f in opened.values():
                f.close()


def delete_messages(api_base: str, token: str, chat_id: str, message_ids: list[int]) -> None:
    """发布中途失败时回收已发出的消息，让 CI 重跑可以从零开始、不产生重复。

    尽力而为：单条删除失败只打日志，不掩盖原始错误。
    """
    url = f"{api_base}/bot{token}/deleteMessage"
    for mid in reversed(message_ids):
        try:
            resp = requests.post(
                url, data={"chat_id": chat_id, "message_id": mid}, timeout=60
            )
            try:
                ok = resp.json().get("ok", False)
            except ValueError:
                ok = False
            print(f"deleteMessage {mid}: {'OK' if ok else resp.text[:200]}")
        except requests.RequestException as e:
            print(f"deleteMessage {mid} 异常: {e}")


# === 主流程 ===

def main() -> int:
    token = os.getenv("TELEGRAM_BOT_TOKEN")
    chat_id = os.getenv("TELEGRAM_CHAT_ID")
    if not token or not chat_id:
        print("Missing TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID, skipping.")
        return 0

    api_base = os.getenv("TELEGRAM_API_BASE", "http://localhost:8081").rstrip("/")

    repo = os.getenv("GITHUB_REPOSITORY", "")
    owner = repo.split("/")[0] if "/" in repo else ""
    run_id = os.getenv("GITHUB_RUN_ID", "")
    version = os.getenv("VERSION") or os.getenv("GITHUB_REF_NAME", "").lstrip("v")
    is_prerelease = os.getenv("IS_PRERELEASE", "false").lower() == "true"

    # hashtag 放粗体外的纯文本里，TG 才会识别，方便频道内按版本类型过滤
    if is_prerelease:
        title_html = f"🧪 <b>FluxDO v{html_escape(version)}（预发布）</b> #beta"
    else:
        title_html = f"🚀 <b>FluxDO v{html_escape(version)}</b> #stable"

    notes_html = ""
    compare: tuple[str, str, str] | None = None
    contributors: list[str] = []
    release_notes = Path(os.getenv("RELEASE_NOTES_FILE", "release_notes.md"))
    if release_notes.exists():
        notes_md = release_notes.read_text(encoding="utf-8").strip()
        if notes_md:
            notes_md, compare = extract_compare_link(notes_md)
            notes_md, authors = strip_authors(notes_md)
            contributors = [u for u in authors if u.lower() != owner.lower()]
            notes_html = md_to_html(tidy_notes(notes_md))

    # 正文可能是人工亮点版（不含 " by @user" 后缀），贡献者致谢固定从
    # cliff 明细快照收集，两者解耦
    detail_notes = Path(os.getenv("RELEASE_NOTES_DETAIL_FILE", "release_notes_detail.md"))
    if detail_notes.exists():
        _, authors = strip_authors(detail_notes.read_text(encoding="utf-8"))
        contributors = [u for u in authors if u.lower() != owner.lower()]

    link_parts: list[str] = []
    if repo and version and not is_prerelease:
        url = f"https://github.com/{repo}/releases/tag/v{version}"
        link_parts.append(f'📥 <a href="{html_escape(url, quote=True)}">GitHub Release</a>')
    elif repo and run_id:
        url = f"https://github.com/{repo}/actions/runs/{run_id}"
        link_parts.append(f'🔍 <a href="{html_escape(url, quote=True)}">构建日志</a>')
    if compare:
        url, prev_tag, curr_tag = compare
        link_parts.append(
            f'📋 <a href="{html_escape(url, quote=True)}">'
            f"{html_escape(prev_tag)} → {html_escape(curr_tag)}</a>"
        )
    links_html = " · ".join(link_parts)

    thanks_html = ""
    if contributors:
        thanks_html = "🙏 感谢贡献：" + "、".join(
            f'<a href="https://github.com/{html_escape(u, quote=True)}">@{html_escape(u)}</a>'
            for u in contributors
        )

    artifacts_dir = Path("dist")
    package_files: list[Path] = []
    if artifacts_dir.exists():
        package_files = sorted(
            p
            for p in artifacts_dir.iterdir()
            if p.is_file() and p.suffix in {".apk", ".ipa", ".dmg", ".exe", ".flatpak"}
        )

    files_hint = "<i>📦 安装包见下方文件</i>" if package_files else ""

    def assemble(notes: str) -> str:
        return "\n\n".join(
            p for p in (title_html, links_html, notes, thanks_html, files_hint) if p
        )

    text_html = assemble(notes_html)

    # stable 折叠整个 beta 周期，notes 可能很长；它有 GitHub Release 兜底，
    # 超长时按行截断收进单条消息，不像 beta 那样分片刷屏
    if not is_prerelease and notes_html and len(text_html) > MESSAGE_LIMIT:
        suffix = "\n\n<i>……更新日志过长已截断，完整版见上方 GitHub Release</i>"
        budget = MESSAGE_LIMIT - (len(text_html) - len(notes_html)) - len(suffix)
        cut = notes_html.rfind("\n", 0, max(budget, 0))
        if cut > 0:
            text_html = assemble(notes_html[:cut].rstrip() + suffix)

    if not package_files:
        print("No package files found in dist/, sending message only.")

    sent_ids: list[int] = []
    try:
        root_id = send_message(api_base, token, chat_id, text_html, sent_ids)
        if package_files:
            send_files(
                api_base, token, chat_id, package_files, version,
                sent_ids, reply_to=root_id,
            )
    except Exception:
        if sent_ids:
            print(f"发布中断，回收已发出的 {len(sent_ids)} 条消息，重跑时从零开始")
            delete_messages(api_base, token, chat_id, sent_ids)
        raise
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
