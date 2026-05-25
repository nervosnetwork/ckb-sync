import json
import os
import sys
import urllib.error
import urllib.request

from dotenv import load_dotenv


if len(sys.argv) < 2:
    print("使用方法: python3 sendMsg.py <文件名> [<环境变量文件>]")
    sys.exit(1)

env_file = sys.argv[2] if len(sys.argv) > 2 else ".env"
load_dotenv(env_file)

TOKEN = os.getenv("DISCORD_TOKEN")
CHANNEL_ID_TEXT = os.getenv("DISCORD_CHANNEL_ID")

if not TOKEN or not CHANNEL_ID_TEXT:
    print(f"环境变量文件 {env_file} 缺少 DISCORD_TOKEN 或 DISCORD_CHANNEL_ID", file=sys.stderr)
    sys.exit(1)

try:
    CHANNEL_ID = int(CHANNEL_ID_TEXT)
except ValueError:
    print(f"DISCORD_CHANNEL_ID 不是有效数字: {CHANNEL_ID_TEXT}", file=sys.stderr)
    sys.exit(1)

try:
    SEND_TIMEOUT = int(os.getenv("DISCORD_SEND_TIMEOUT", "30"))
except ValueError:
    SEND_TIMEOUT = 30

file_name = sys.argv[1]

try:
    with open(file_name, "r", encoding="utf-8") as file:
        message_content = file.read()
except UnicodeDecodeError:
    with open(file_name, "r") as file:
        message_content = file.read()
except FileNotFoundError:
    print(f"找不到文件: {file_name}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"读取文件时出错: {e}", file=sys.stderr)
    sys.exit(1)


def split_message(content, limit=1900):
    lines = content.splitlines(keepends=True)
    chunks = []
    current = ""

    for line in lines:
        if len(line) > limit:
            if current:
                chunks.append(current)
                current = ""
            for offset in range(0, len(line), limit):
                chunks.append(line[offset : offset + limit])
            continue

        if len(current) + len(line) > limit:
            chunks.append(current)
            current = line
        else:
            current += line

    if current:
        chunks.append(current)

    return chunks or ["(empty report)"]


def send_discord_message(content):
    url = f"https://discord.com/api/v10/channels/{CHANNEL_ID}/messages"
    payload = {
        "content": content,
        "allowed_mentions": {"parse": []},
    }
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={
            "Authorization": f"Bot {TOKEN}",
            "Content-Type": "application/json",
            "User-Agent": "ckb-sync-report/1.0",
        },
    )

    with urllib.request.urlopen(request, timeout=SEND_TIMEOUT) as response:
        response.read()
        return response.status


try:
    chunks = split_message(message_content)
    for index, chunk in enumerate(chunks, start=1):
        prefix = "" if len(chunks) == 1 else f"[{index}/{len(chunks)}]\n"
        status = send_discord_message(prefix + chunk)
        print(f"已发送到频道 {CHANNEL_ID}, HTTP {status}")
except urllib.error.HTTPError as e:
    detail = e.read().decode("utf-8", errors="replace")
    print(f"Discord API HTTP {e.code}: {detail}", file=sys.stderr)
    sys.exit(1)
except urllib.error.URLError as e:
    print(f"Discord API 网络错误: {e.reason}", file=sys.stderr)
    sys.exit(1)
except TimeoutError:
    print(f"Discord API 超时: {SEND_TIMEOUT} 秒", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"发送消息时出错: {e}", file=sys.stderr)
    sys.exit(1)
