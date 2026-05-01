import html
import hashlib
import json
import mimetypes
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

from archive_store import (
    init_db,
    load_history,
    register_conversation,
    register_raw_source,
    save_history,
    update_conversation_metadata,
)


USER_NAME = "User"
AI_NAME = "Madini"
AI_KEYWORDS = ["ai", "assistant", "gpt", "claude", "gemini", "madini", AI_NAME.lower()]
MODEL_VALUE_RE = re.compile(
    r"^(?:gpt-[A-Za-z0-9._-]+|claude(?:[- ][A-Za-z0-9._-]+)+|gemini(?:[- ][A-Za-z0-9._-]+)+|(?:haiku|sonnet|opus|flash|pro|ultra)(?:[- ][A-Za-z0-9._-]+)*)$",
    re.IGNORECASE,
)
TEXT_SOURCE_SUFFIXES = {
    ".json": ("json", "application/json"),
    ".md": ("markdown", "text/markdown"),
    ".markdown": ("markdown", "text/markdown"),
}


def _format_timestamp(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        try:
            return datetime.fromtimestamp(float(value)).strftime("%Y-%m-%d %H:%M:%S")
        except (OverflowError, OSError, ValueError):
            return None

    text = str(value).strip()
    if not text:
        return None
    if re.fullmatch(r"\d+(?:\.\d+)?", text):
        try:
            return datetime.fromtimestamp(float(text)).strftime("%Y-%m-%d %H:%M:%S")
        except (OverflowError, OSError, ValueError):
            return None
    try:
        normalized = text.replace("Z", "+00:00")
        return datetime.fromisoformat(normalized).strftime("%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None


def _get_file_source_created_at(path):
    try:
        stat = path.stat()
    except OSError:
        return None
    filesystem_timestamp = getattr(stat, "st_birthtime", None) or stat.st_mtime
    return _format_timestamp(filesystem_timestamp)


def _build_raw_source_record(path):
    suffix = path.suffix.lower()
    source_format, default_mime_type = TEXT_SOURCE_SUFFIXES.get(
        suffix,
        ("text", "text/plain"),
    )
    raw_text = path.read_text(encoding="utf-8")
    mime_type = mimetypes.guess_type(str(path))[0] or default_mime_type
    raw_bytes = raw_text.encode("utf-8")
    return {
        "source_hash": hashlib.sha256(raw_bytes).hexdigest(),
        "source_format": source_format,
        "source_path": str(path.resolve()),
        "source_created_at": _get_file_source_created_at(path),
        "mime_type": mime_type,
        "size_bytes": len(raw_bytes),
        "text_encoding": "utf-8",
        "raw_text": raw_text,
        "raw_bytes_path": None,
    }


def _current_imported_at():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def _normalize_model_name(value):
    text = str(value or "").strip()
    if not text:
        return None
    text = text.replace("models/", "").strip()
    text = re.sub(r"\s+", " ", text)
    return text or None


def _extract_model_from_text(text):
    if not text:
        return None
    normalized = _normalize_model_name(text)
    if not normalized:
        return None
    if len(normalized) > 80:
        return None
    if not MODEL_VALUE_RE.match(normalized):
        return None
    return normalized


def _extract_model_from_obj(obj):
    if obj is None:
        return None
    if isinstance(obj, str):
        return _extract_model_from_text(obj)
    if isinstance(obj, list):
        for item in obj:
            model = _extract_model_from_obj(item)
            if model:
                return model
        return None
    if isinstance(obj, dict):
        preferred_keys = [
            "model_slug",
            "resolved_model_slug",
            "requested_model_slug",
            "default_model_slug",
            "model",
            "modelCode",
            "model_code",
            "modelName",
            "model_name",
        ]
        for key in preferred_keys:
            if key in obj:
                model = _extract_model_from_obj(obj.get(key))
                if model:
                    return model
        for key, value in obj.items():
            if any(token in key.lower() for token in ["model", "slug"]):
                model = _extract_model_from_obj(value)
                if model:
                    return model
        for value in obj.values():
            if isinstance(value, (dict, list)):
                model = _extract_model_from_obj(value)
                if model:
                    return model
    return None


def gemini_html_to_md(html_str):
    if not html_str:
        return ""

    text = html_str

    def process_table(match):
        content = (
            match.group(1)
            .replace("<thead>", "")
            .replace("</thead>", "")
            .replace("<tbody>", "")
            .replace("</tbody>", "")
        )
        content = re.sub(r"<tr[^>]*>", "|", content).replace("</tr>", "|\n")
        content = re.sub(r"<th[^>]*>", "", content).replace("</th>", "|")
        content = re.sub(r"<td[^>]*>", "", content).replace("</td>", "|")
        lines = [line.strip() for line in content.strip().split("\n") if line.strip()]
        if not lines:
            return ""
        col_count = lines[0].count("|") - 1
        if col_count > 0:
            lines.insert(1, "|" + "|".join(["---"] * col_count) + "|")
        return "\n\n" + "\n".join(lines) + "\n\n"

    text = re.sub(r"<table[^>]*>(.*?)</table>", process_table, text, flags=re.DOTALL)
    for level in range(1, 7):
        text = re.sub(
            fr"<h{level}[^>]*>(.*?)</h{level}>",
            lambda match: "\n\n" + ("#" * level) + " " + match.group(1) + "\n\n",
            text,
            flags=re.DOTALL,
        )
    text = text.replace("<ul>", "\n").replace("</ul>", "\n")
    text = text.replace("<ol>", "\n").replace("</ol>", "\n")
    text = re.sub(r"<li[^>]*>(.*?)</li>", r"- \1\n", text, flags=re.DOTALL)
    text = re.sub(r'<a href="(.*?)">(.*?)</a>', r"[\2](\1)", text)
    text = re.sub(r"<strong[^>]*>(.*?)</strong>", r"**\1**", text, flags=re.DOTALL)
    text = re.sub(r"<b[^>]*>(.*?)</b>", r"**\1**", text, flags=re.DOTALL)
    text = re.sub(r"<em[^>]*>(.*?)</em>", r"*\1*", text, flags=re.DOTALL)
    text = re.sub(r"<i[^>]*>(.*?)</i>", r"*\1*", text, flags=re.DOTALL)
    text = (
        text.replace("<p>", "")
        .replace("</p>", "\n\n")
        .replace("<br>", "\n")
        .replace("<br/>", "\n")
        .replace("<br />", "\n")
        .replace("<hr>", "\n---\n")
    )
    text = re.sub(
        r"<pre[^>]*><code[^>]*>(.*?)</code></pre>",
        lambda match: "\n```\n" + match.group(1).strip() + "\n```\n",
        text,
        flags=re.DOTALL,
    )
    text = re.sub(
        r"<pre[^>]*>(.*?)</pre>",
        lambda match: "\n```\n" + match.group(1).strip() + "\n```\n",
        text,
        flags=re.DOTALL,
    )
    text = re.sub(r"<code[^>]*>(.*?)</code>", r"`\1`", text, flags=re.DOTALL)

    def process_blockquote(match):
        return "\n\n" + "\n".join("> " + line for line in match.group(1).strip().split("\n")) + "\n\n"

    text = re.sub(r"<blockquote[^>]*>(.*?)</blockquote>", process_blockquote, text, flags=re.DOTALL)
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def _finalize_messages(messages):
    return [message for message in messages if message.get("text")]


def parse_markdown_file(path, raw_text=None):
    text = raw_text if raw_text is not None else path.read_text(encoding="utf-8")
    messages = []
    current_role = "user"
    current_text = []

    for line in text.split("\n"):
        is_header = line.startswith("#")
        has_role_hint = any(
            keyword in line.lower()
            for keyword in AI_KEYWORDS + ["user", "自分", USER_NAME.lower()]
        )
        if is_header and has_role_hint:
            if current_text:
                messages.append({"role": current_role, "text": "\n".join(current_text).strip()})
            current_text = []
            current_role = "assistant" if any(keyword in line.lower() for keyword in AI_KEYWORDS) else "user"
        else:
            current_text.append(line)

    if current_text:
        messages.append({"role": current_role, "text": "\n".join(current_text).strip()})

    messages = _finalize_messages(messages)
    if not messages:
        return []

    return [
        {
            "conv_id": path.name,
            "source": "markdown",
            "title": path.stem,
            "source_created_at": _get_file_source_created_at(path),
            "messages": messages,
        }
    ]


def _join_chatgpt_thoughts(thoughts):
    """Flatten ChatGPT's `thoughts` array into a single string. Each
    element is either a plain string or a `{summary, content}` dict
    (o3 / research models include both — the summary is a one-line
    title for each reasoning step, the content is the prose). Joins
    with double newlines so the Swift reader can treat each entry as
    a paragraph if it wants to."""
    parts = []
    for entry in thoughts or []:
        if isinstance(entry, str):
            text = entry.strip()
            if text:
                parts.append(text)
        elif isinstance(entry, dict):
            summary = (entry.get("summary") or "").strip()
            content = (entry.get("content") or "").strip()
            if summary and content:
                parts.append(f"{summary}\n\n{content}")
            elif content:
                parts.append(content)
            elif summary:
                parts.append(summary)
    return "\n\n".join(parts)


def _build_chatgpt_message_blocks(message):
    """Build a thinking-block list from a single ChatGPT message node
    when its content carries reasoning data (o3 / research models).
    Returns `None` for ordinary text / multimodal / code messages —
    those continue to flow through the flat `content` column.

    ChatGPT puts reasoning in DEDICATED nodes (separate `mapping`
    entries with `content_type` of `thoughts` or `reasoning_recap`),
    not inline alongside the response text. The current importer
    drops those nodes silently because their `content.parts` is
    empty. Phase 2b reroutes them: when `parse_chatgpt_export` sees a
    reasoning node, it calls this helper, buffers the thinking
    blocks, and attaches them to the next assistant text message —
    so the response and its reasoning land on a single row in the
    `messages` table without changing the row count or the hash."""
    content = message.get("content")
    if not isinstance(content, dict):
        return None
    content_type = content.get("content_type")

    if content_type == "thoughts":
        joined = _join_chatgpt_thoughts(content.get("thoughts"))
        if not joined:
            return None
        metadata = {}
        if "source_analysis_msg_id" in content:
            metadata["source_analysis_msg_id"] = content["source_analysis_msg_id"]
        return [{
            "type": "thinking",
            "provider": "chatgpt",
            "text": joined,
            "metadata": metadata,
        }]

    if content_type == "reasoning_recap":
        # The `reasoning_recap` node carries a short headline ("思考時間: 49 秒")
        # rather than the full chain — useful as a label so the user
        # can see "this answer used reasoning" without expanding the
        # full thinking. Marked with `recap: True` so the Swift reader
        # can render it differently if desired.
        recap = (content.get("content") or "").strip()
        if not recap:
            return None
        return [{
            "type": "thinking",
            "provider": "chatgpt",
            "text": recap,
            "metadata": {"recap": True},
        }]

    return None


def parse_chatgpt_export(data):
    conversations = []
    for conv in data:
        messages = []
        message_timestamps = []
        conversation_model = _extract_model_from_obj(
            {
                "model_slug": conv.get("default_model_slug"),
                "resolved_model_slug": conv.get("resolved_model_slug"),
                "requested_model_slug": conv.get("requested_model_slug"),
                "mapping": conv.get("mapping"),
            }
        )
        nodes = sorted(
            [node for node in conv.get("mapping", {}).values() if node.get("message")],
            key=lambda item: item["message"].get("create_time") or 0,
        )
        # Phase 2b: ChatGPT o3 / research models emit reasoning as
        # dedicated nodes (`content_type` of `thoughts` or
        # `reasoning_recap`) that arrive just before the assistant's
        # text response. Buffer them here and attach to the next
        # text-bearing assistant message so reasoning and response
        # land on a single `messages` row. Reset on every user turn
        # to drop orphaned reasoning that didn't get a response (rare
        # but possible — interrupted generation, deleted branches).
        pending_thinking_blocks = []
        for node in nodes:
            message = node["message"]
            role = message.get("author", {}).get("role")
            if role not in {"user", "assistant"}:
                continue
            if conversation_model is None:
                conversation_model = _extract_model_from_obj(
                    message.get("metadata") or {}
                )
            timestamp = _format_timestamp(message.get("create_time"))
            if timestamp:
                message_timestamps.append(timestamp)

            if role == "user":
                # User turn boundary — discard any reasoning buffered
                # from a previous assistant turn that never produced
                # a visible response.
                pending_thinking_blocks = []
            elif role == "assistant":
                reasoning_blocks = _build_chatgpt_message_blocks(message)
                if reasoning_blocks is not None:
                    # Reasoning-only node. Buffer and skip — it
                    # carries no `parts` to surface as user-visible
                    # text, so emitting it as its own message row
                    # would (a) be invisible in the existing reader
                    # (`content` is empty) and (b) shift `msg_index`
                    # for subsequent rows, breaking the hash
                    # stability we rely on for dedup.
                    pending_thinking_blocks.extend(reasoning_blocks)
                    continue

            text = "\n\n".join(
                str(part)
                for part in message.get("content", {}).get("parts", [])
                if isinstance(part, str)
            ).strip()
            if text:
                # Attach any buffered reasoning to this text message.
                # Construct a full block list (reasoning + visible
                # response) so the Swift reader can render the
                # message structurally; the flat `content` column
                # still holds just the response text for hash
                # stability and for legacy callers.
                if pending_thinking_blocks:
                    blocks = pending_thinking_blocks + [
                        {"type": "text", "text": text}
                    ]
                    pending_thinking_blocks = []
                else:
                    blocks = None
                messages.append({"role": role, "text": text, "blocks": blocks})

        messages = _finalize_messages(messages)
        if messages:
            conversation_source_created_at = (
                _format_timestamp(conv.get("create_time"))
                or (min(message_timestamps) if message_timestamps else None)
            )
            conversations.append(
                {
                    "conv_id": conv.get("conversation_id") or conv.get("id", ""),
                    "source": "chatgpt",
                    "title": conv.get("title", "Untitled"),
                    "model": conversation_model,
                    "source_created_at": conversation_source_created_at,
                    "messages": messages,
                }
            )
    return conversations


CLAUDE_TOOL_PLACEHOLDER = "```\nThis block is not supported on your current device yet.\n```"


def _summarize_claude_tool_input(name, inputs):
    """Pick the most informative single-key value from a Claude `tool_use`
    input dict. Falls back to listing input keys when nothing scalar-ish
    fits. Output is intentionally short — tool blocks are rendered inline
    and shouldn't dominate the message body."""
    if not isinstance(inputs, dict) or not inputs:
        return ""
    PRIORITIZED_KEYS = ("query", "url", "path", "title", "name", "command", "code", "text")
    for key in PRIORITIZED_KEYS:
        value = inputs.get(key)
        if isinstance(value, (str, int, float)) and str(value).strip():
            text = str(value).strip()
            if len(text) > 140:
                text = text[:140].rstrip() + "…"
            return f"{key}: {text}"
    keys = [k for k in list(inputs.keys())[:4] if k]
    return f"inputs: {', '.join(keys)}" if keys else ""


def _format_claude_tool_block(item):
    """Render a single `tool_use` or `tool_result` content item as a short
    Markdown blockquote. Used to replace Claude's export-side placeholder
    string ('This block is not supported on your current device yet.')
    with the actual tool name + a brief input summary, so the user can
    see which tool ran instead of an opaque stub."""
    if not isinstance(item, dict):
        return CLAUDE_TOOL_PLACEHOLDER
    kind = item.get("type")
    name = (item.get("name") or "unknown").strip() or "unknown"
    if kind == "tool_use":
        summary = _summarize_claude_tool_input(name, item.get("input"))
        return f"> 🔧 **{name}** — {summary}" if summary else f"> 🔧 **{name}**"
    if kind == "tool_result":
        if item.get("is_error"):
            msg = item.get("message") or "tool returned an error"
            return f"> ⚠️ **{name}** failed — {str(msg)[:120]}"
        # Successful tool_result is mostly redundant once the tool_use
        # above has already surfaced what ran. Drop it to keep the
        # message readable instead of doubling every tool with a
        # confirmation line.
        return ""
    return CLAUDE_TOOL_PLACEHOLDER


def _claude_tool_result_summary(item):
    """Short text representation of a Claude `tool_result` content item.
    Errors return the API-side error message; successful results pull
    the first text item from the `content` list (which is what the
    user actually sees, e.g. `web_fetch` body, `view` file contents).
    Truncated to keep the JSON column from ballooning when a tool
    result is megabytes of HTML."""
    if item.get("is_error"):
        msg = item.get("message") or "tool returned an error"
        return str(msg)[:240]
    content = item.get("content")
    if isinstance(content, list):
        for entry in content:
            if isinstance(entry, dict) and entry.get("type") == "text":
                text = (entry.get("text") or "").strip()
                if text:
                    return text[:1000]
    if isinstance(content, str):
        return content.strip()[:1000]
    return ""


def _extract_claude_thinking_metadata(item):
    """Preserve a small whitelisted set of provider-specific fields on a
    Claude `thinking` block so the Swift reader can show signed
    timestamps / signature info if it ever wants to. Whitelist (rather
    than copying everything) keeps the JSON column from inflating with
    fields Anthropic might add later."""
    keys = ("start_timestamp", "stop_timestamp", "signature", "cut_off", "truncated")
    return {key: item[key] for key in keys if key in item}


def _build_claude_message_blocks(message):
    """Build the structured block list for a Claude assistant / user
    message from its `content[]` array. Returns `None` when the
    message has nothing structured worth preserving (no thinking, no
    tool calls, no artifacts) — in that case the flat `content` column
    is a sufficient canonical form and `content_json` stays NULL.

    Block types emitted (provider-agnostic schema, see
    `docs/plans/thinking-preservation-2026-04-30.md` §2.2):
      - {"type": "text", "text": str}
      - {"type": "thinking", "provider": "claude", "text": str,
         "metadata": {...}}
      - {"type": "tool_use", "name": str, "input_summary": str}
      - {"type": "tool_result", "name": str, "is_error": bool,
         "summary": str}
      - {"type": "artifact", "identifier": str, "title": str|None,
         "kind": str|None, "content": str}

    Unknown content `type` values are silently dropped — defensive
    against future Anthropic additions, the trade-off is the Swift
    reader sees a "...[unsupported block]..." placeholder instead of
    raw schema fragments."""
    content = message.get("content")
    if not isinstance(content, list) or not content:
        return None

    structured_types = {
        "thinking", "redacted_thinking",
        "tool_use", "tool_result",
        "artifact",
    }
    has_structured = any(
        isinstance(item, dict) and item.get("type") in structured_types
        for item in content
    )
    if not has_structured:
        # Pure text-only content[] — flat `content` column already
        # captures everything. Save the JSON-column space.
        return None

    blocks = []
    for item in content:
        if not isinstance(item, dict):
            continue
        item_type = item.get("type")
        if item_type == "text":
            text = (item.get("text") or "").strip()
            if text:
                blocks.append({"type": "text", "text": text})
        elif item_type in ("thinking", "redacted_thinking"):
            text = (item.get("thinking") or item.get("text") or "").strip()
            if text:
                blocks.append({
                    "type": "thinking",
                    "provider": "claude",
                    "text": text,
                    "metadata": _extract_claude_thinking_metadata(item),
                })
        elif item_type == "tool_use":
            blocks.append({
                "type": "tool_use",
                "name": (item.get("name") or "unknown").strip() or "unknown",
                "input_summary": _summarize_claude_tool_input(
                    item.get("name") or "", item.get("input")
                ),
            })
        elif item_type == "tool_result":
            blocks.append({
                "type": "tool_result",
                "name": (item.get("name") or "unknown").strip() or "unknown",
                "is_error": bool(item.get("is_error")),
                "summary": _claude_tool_result_summary(item),
            })
        elif item_type == "artifact":
            blocks.append({
                "type": "artifact",
                "identifier": str(item.get("id") or item.get("identifier") or ""),
                "title": item.get("title"),
                "kind": item.get("type_") or item.get("kind") or item.get("language"),
                "content": (item.get("content") or "")[:8000],
            })
        # Unknown types are dropped intentionally.
    return blocks if blocks else None


def _build_claude_message_text(message):
    """Replace each `This block is not supported on your current device yet.`
    placeholder fence-block in `message.text` with a contextual summary
    pulled from the matching item in `message.content[]`. Claude's
    export embeds the placeholder once per `tool_use` and once per
    `tool_result` — we walk both arrays in lockstep so the i-th
    placeholder gets the i-th tool block's summary. When the counts don't
    match (defensive — never seen in practice), surplus placeholders are
    left as-is rather than risk grafting a wrong tool's name onto an
    unrelated block."""
    text = (message.get("text") or "").strip()
    if not text or CLAUDE_TOOL_PLACEHOLDER not in text:
        return text
    content = message.get("content") or []
    tool_blocks = [
        item for item in content
        if isinstance(item, dict) and item.get("type") in ("tool_use", "tool_result")
    ]
    parts = text.split(CLAUDE_TOOL_PLACEHOLDER)
    rebuilt = parts[0]
    for i, tail in enumerate(parts[1:]):
        if i < len(tool_blocks):
            replacement = _format_claude_tool_block(tool_blocks[i])
        else:
            replacement = CLAUDE_TOOL_PLACEHOLDER
        rebuilt += replacement + tail
    # Empty replacements (successful tool_result) leave bare blank lines
    # behind. Collapse 3+ newlines back to a paragraph break so the
    # resulting Markdown doesn't render with huge gaps.
    return re.sub(r"\n{3,}", "\n\n", rebuilt).strip()


def parse_claude_export(data):
    conversations = []
    for conv in data:
        messages = []
        message_timestamps = []
        conversation_model = _extract_model_from_obj(conv)
        for message in sorted(conv.get("chat_messages", []), key=lambda item: item.get("created_at", "")):
            sender = message.get("sender")
            role = "user" if sender == "human" else "assistant" if sender == "assistant" else None
            if conversation_model is None:
                conversation_model = _extract_model_from_obj(message)
            timestamp = _format_timestamp(message.get("created_at"))
            if timestamp:
                message_timestamps.append(timestamp)
            text = _build_claude_message_text(message)
            blocks = _build_claude_message_blocks(message)
            if role and text:
                # `blocks` is supplementary to `text`. When a Claude
                # message has only `content[].text` items (no
                # thinking, no tool calls), `_build_claude_message_blocks`
                # returns None and we leave `content_json` NULL —
                # the flat text column is already the complete
                # canonical form. The hash-stable inclusion criterion
                # `text` (unchanged from before Phase 2) keeps the
                # message inventory and conversation hash identical
                # to pre-Phase-2 imports.
                messages.append({"role": role, "text": text, "blocks": blocks})

        messages = _finalize_messages(messages)
        if messages:
            conversation_source_created_at = (
                _format_timestamp(conv.get("created_at"))
                or (min(message_timestamps) if message_timestamps else None)
            )
            conversations.append(
                {
                    "conv_id": conv.get("uuid", ""),
                    "source": "claude",
                    "title": conv.get("name", "Untitled"),
                    "model": conversation_model,
                    "source_created_at": conversation_source_created_at,
                    "messages": messages,
                }
            )
    return conversations


def parse_gemini_export(data):
    grouped = defaultdict(list)
    for item in data:
        date_key = item.get("time", "").split("T")[0] if "T" in item.get("time", "") else "Unknown Date"
        grouped[date_key].append(item)

    conversations = []
    for date_key, items in grouped.items():
        messages = []
        conversation_model = None
        message_timestamps = []
        for item in sorted(items, key=lambda value: value.get("time", "")):
            if conversation_model is None:
                conversation_model = _extract_model_from_obj(item)
            timestamp = _format_timestamp(item.get("time"))
            if timestamp:
                message_timestamps.append(timestamp)
            prompt = (
                item.get("title", "")
                .replace("送信したメッセージ: ", "")
                .replace(" と言いました", "")
                .replace("Said ", "")
                .strip()
            )
            safe_items = item.get("safeHtmlItem", [])
            response_html = ""
            if safe_items and isinstance(safe_items, list):
                response_html = safe_items[0].get("html", "")
            response = gemini_html_to_md(response_html)
            if prompt:
                messages.append({"role": "user", "text": prompt})
            if response:
                messages.append({"role": "assistant", "text": response})

        messages = _finalize_messages(messages)
        if messages:
            conversations.append(
                {
                    "conv_id": f"gemini_{date_key}",
                    "source": "gemini",
                    "title": f"Geminiの記録 ({date_key})",
                    "model": conversation_model,
                    "source_created_at": min(message_timestamps) if message_timestamps else None,
                    "messages": messages,
                }
            )
    return conversations


def parse_json_file(path, raw_text=None):
    text = raw_text if raw_text is not None else path.read_text(encoding="utf-8")
    data = json.loads(text)
    if not isinstance(data, list) or not data:
        return []

    if "mapping" in data[0]:
        return parse_chatgpt_export(data)
    if "chat_messages" in data[0]:
        return parse_claude_export(data)
    if "time" in data[0] and "title" in data[0]:
        return parse_gemini_export(data)
    return []


def parse_input_file(path, raw_text=None):
    suffix = path.suffix.lower()
    if suffix in {".md", ".markdown"}:
        return parse_markdown_file(path, raw_text=raw_text)
    if suffix == ".json":
        return parse_json_file(path, raw_text=raw_text)
    return []


def import_files(paths):
    conn = init_db()
    cursor = conn.cursor()
    imported_count = 0
    provenance_updated_count = 0
    imported_paths = []

    for path in paths:
        cursor.execute("SAVEPOINT import_file")
        try:
            raw_source = _build_raw_source_record(path)
            imported_at = _current_imported_at()
            conversations = parse_input_file(path, raw_text=raw_source["raw_text"])
        except Exception as exc:
            cursor.execute("ROLLBACK TO SAVEPOINT import_file")
            cursor.execute("RELEASE SAVEPOINT import_file")
            print(f"⚠️ 解析失敗: {path.name} ({exc})")
            continue

        if not conversations:
            cursor.execute("ROLLBACK TO SAVEPOINT import_file")
            cursor.execute("RELEASE SAVEPOINT import_file")
            print(f"💡 取り込み対象が見つからなかったわ: {path.name}")
            continue

        try:
            raw_source_id = register_raw_source(
                cursor,
                raw_source["source_hash"],
                raw_source["source_format"],
                source_path=raw_source["source_path"],
                source_created_at=raw_source["source_created_at"],
                imported_at=imported_at,
                mime_type=raw_source["mime_type"],
                size_bytes=raw_source["size_bytes"],
                text_encoding=raw_source["text_encoding"],
                raw_text=raw_source["raw_text"],
                raw_bytes_path=raw_source["raw_bytes_path"],
            )
            imported_paths.append(str(path))
            for conv in conversations:
                conv.setdefault("model", None)
                conv.setdefault("source_file", path.name)
                conv.setdefault("source_created_at", raw_source["source_created_at"])
                if register_conversation(
                    cursor,
                    conv["conv_id"],
                    conv["source"],
                    conv["title"],
                    conv["messages"],
                    model=conv.get("model"),
                    source_file=conv.get("source_file"),
                    raw_source_id=raw_source_id,
                    source_created_at=conv.get("source_created_at"),
                    imported_at=imported_at,
                ):
                    imported_count += 1
                else:
                    provenance_updated_count += update_conversation_metadata(
                        cursor,
                        conv["conv_id"],
                        model=conv.get("model"),
                        source_file=conv.get("source_file"),
                        raw_source_id=raw_source_id,
                        source_created_at=conv.get("source_created_at"),
                        imported_at=imported_at,
                    )
        except Exception as exc:
            cursor.execute("ROLLBACK TO SAVEPOINT import_file")
            cursor.execute("RELEASE SAVEPOINT import_file")
            print(f"⚠️ 保存失敗: {path.name} ({exc})")
            continue

        cursor.execute("RELEASE SAVEPOINT import_file")

    conn.commit()
    conn.close()

    if imported_count > 0:
        save_history(imported_paths)
        print(f"✨ 新しく {imported_count} 個の物語を登録したわ！")
    elif provenance_updated_count > 0:
        save_history(imported_paths)
        print(f"✨ 新規登録はなかったけれど、{provenance_updated_count} 件の provenance を更新したわ。")
    else:
        print("💡 登録できる新しい物語がなかったわ。（すでに登録済みのデータよ）")


def main(jpaths):
    import_files(jpaths)


def backfill_models_from_paths(paths=None):
    history_paths = [Path(path) for path in load_history()]
    extra_paths = [Path(path) for path in (paths or [])]
    merged_paths = []
    for path in history_paths + extra_paths:
        if path not in merged_paths:
            merged_paths.append(path)
    existing_paths = [path for path in merged_paths if path.exists()]
    if not existing_paths:
        print("💡 model を埋め直せる元ログが見つからなかったわ。")
        return 0

    conn = init_db()
    cursor = conn.cursor()
    updated_count = 0

    for path in existing_paths:
        try:
            conversations = parse_input_file(path)
        except Exception as exc:
            print(f"⚠️ 再解析失敗: {path.name} ({exc})")
            continue

        for conv in conversations:
            model = conv.get("model")
            source_file = conv.get("source_file") or path.name
            source_created_at = conv.get("source_created_at")
            if not model and not source_file and not source_created_at:
                continue
            updated_count += update_conversation_metadata(
                cursor,
                conv["conv_id"],
                model=model,
                source_file=source_file,
                source_created_at=source_created_at,
            )

    conn.commit()
    conn.close()
    print(f"✨ model / source file を {updated_count} 件更新したわ。")
    return updated_count


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--backfill-models":
        backfill_models_from_paths(sys.argv[2:])
    elif len(sys.argv) >= 2:
        main([Path(path) for path in sys.argv[1:]])
