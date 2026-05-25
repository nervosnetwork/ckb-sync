import discord
import sys
from dotenv import load_dotenv
import os
import asyncio

# 检查是否有足够的参数，至少需要一个文件名
if len(sys.argv) < 2:
    print("使用方法: python3 sendMsg.py <文件名> [<环境变量文件>]")
    sys.exit(1)

# 环境文件参数是可选的
env_file = sys.argv[2] if len(sys.argv) > 2 else '.env'

# 加载环境变量
load_dotenv(env_file)

# 从环境变量中获取TOKEN和CHANNEL_ID
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
    SEND_TIMEOUT = int(os.getenv("DISCORD_SEND_TIMEOUT", "120"))
except ValueError:
    SEND_TIMEOUT = 120

# 获取文件名
file_name = sys.argv[1]

# 读取文件内容
try:
    with open(file_name, 'r') as file:
        message_content = file.read()
except FileNotFoundError:
    print(f"找不到文件: {file_name}")
    sys.exit(1)
except Exception as e:
    print(f"读取文件时出错: {e}")
    sys.exit(1)

intents = discord.Intents.default()
intents.message_content = True

# 声明一个客户端
client = discord.Client(intents=intents)
send_error = None


# 当客户端准备好时触发的事件处理器
@client.event
async def on_ready():
    global send_error
    print(f'已登录为 {client.user}')

    try:
        # 发送消息到指定的频道。缓存里没有时主动 fetch，避免 channel 为 None 后客户端挂住。
        channel = client.get_channel(CHANNEL_ID)
        if channel is None:
            channel = await client.fetch_channel(CHANNEL_ID)

        await channel.send(message_content)
        print(f"已发送到频道 {CHANNEL_ID}")
    except Exception as e:
        send_error = e
        print(f"发送消息时出错: {e}", file=sys.stderr)
    finally:
        await client.close()


# 运行客户端
async def main():
    try:
        await asyncio.wait_for(client.start(TOKEN), timeout=SEND_TIMEOUT)
    except asyncio.TimeoutError:
        await client.close()
        print(f"发送消息超时: {SEND_TIMEOUT} 秒", file=sys.stderr)
        return 1
    except Exception as e:
        await client.close()
        print(f"Discord 客户端错误: {e}", file=sys.stderr)
        return 1

    if send_error is not None:
        return 1

    return 0


sys.exit(asyncio.run(main()))
